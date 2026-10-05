/*
 * depth_stream: poll the PL's frame-done toggle bit, and when a new frame
 * has landed, stream the 160x120 disparity frame out over UDP in small
 * chunks.
 *
 * Tuning (rectification offsets, camera registers, resend) lives in
 * cam_ctrl.c on its own UDP port. Nothing in this file may write the
 * control GPIO: cam_ctrl keeps a shadow of it, and a blind whole-register
 * write here would silently clobber the SCCB bus-ownership bits.
 */
#include <string.h>

#include "xil_io.h"
#include "xil_printf.h"
#include "lwip/udp.h"
#include "lwip/pbuf.h"

#include "depth_stream.h"
#include "cam_ctrl.h"

/* The disparity frame is packed 4 pixels/32-bit word in the PL (see
 * stereo_depth_top.vhd's disp_byte_we/disp_word_addr), but AXI is
 * byte-addressable and both sides are little-endian, so a straight
 * byte-indexed read through this window recovers the individual pixel
 * bytes directly -- no manual unpacking needed in software.
 *
 * No cache maintenance is done around these reads, and that is a real
 * dependency rather than an oversight: the Zynq-7000 standalone BSP's
 * default MMU translation table maps the PL AXI aperture
 * (0x4000_0000-0x7FFF_FFFF, which is where build_bd.tcl assigns this
 * window) as Device memory, i.e. non-cacheable, so every read here goes
 * straight to the PL. If that translation table is ever customized to make
 * this region cacheable, this code must gain an
 * Xil_DCacheInvalidateRange() before each frame read or it will happily
 * stream stale frames. */
static volatile u8 * const disp_frame = (volatile u8 *)DEPTH_BRAM_BASEADDR;

/* Preview windows hold 4-bit pixels packed 8 per 32-bit word. Read as
 * words, unpack to one byte per pixel, and scale 0-15 to 0-255 so the
 * receiver can treat every plane identically as 8-bit grayscale. */
static volatile u32 * const prev_win[2] = {
	(volatile u32 *)DEPTH_PREV1_BASEADDR,
	(volatile u32 *)DEPTH_PREV2_BASEADDR,
};
static u8 prev_line[DEPTH_CHUNK_PIXELS];

/* Which raw-camera previews to include in each set. Bit 0 = camera 1,
 * bit 1 = camera 2. Set over UDP (CMD_SET_PLANES); disabling one gives the
 * depth plane a larger share of the frame budget. */
static u8 preview_mask = 0x3;

void depth_stream_set_planes(u8 mask)
{
	preview_mask = mask & 0x3;
}

static struct udp_pcb *tx_pcb;
static ip_addr_t dest_ip;
static u8 dest_set;
static u16 frame_id;

void depth_stream_set_dest(u8 a, u8 b, u8 c, u8 d)
{
	IP4_ADDR(&dest_ip, a, b, c, d);
	dest_set = 1;
}

int start_application(void)
{
	err_t err;

	if (!dest_set) {
		/* No destination configured -- default to the laptop end of
		 * the board's dedicated point-to-point link (matches
		 * eth_test's proven static-IP setup, see docs/BOARD_CONFIG.md). */
		depth_stream_set_dest(192, 168, 2, 1);
	}

	tx_pcb = udp_new();
	if (!tx_pcb) {
		xil_printf("depth_stream: udp_new (tx) failed\r\n");
		return -1;
	}
	err = udp_connect(tx_pcb, &dest_ip, DEPTH_DEST_PORT);
	if (err != ERR_OK) {
		xil_printf("depth_stream: udp_connect failed: %d\r\n", err);
		return -2;
	}

	if (cam_ctrl_start() != 0) {
		xil_printf("depth_stream: tuning server failed to start\r\n");
		return -5;
	}

	xil_printf("depth_stream: streaming %dx%d disparity frames, UDP port %d\r\n",
	           DEPTH_FRAME_WIDTH, DEPTH_FRAME_HEIGHT, DEPTH_DEST_PORT);
	return 0;
}

/* Fill buf with `n` pixels of `plane` starting at pixel `offset`. */
static const u8 *plane_chunk(u8 plane, u16 offset, u16 n)
{
	if (plane == PLANE_DEPTH) {
		return (const u8 *)disp_frame + offset;   /* already byte-per-pixel */
	}

	volatile const u32 *win = prev_win[plane == PLANE_CAM1 ? 0 : 1];
	for (u16 i = 0; i < n; i++) {
		u32 pix = offset + i;
		u32 w   = win[pix >> 3];
		u8  nib = (u8)((w >> ((pix & 7) * 4)) & 0xF);
		prev_line[i] = (u8)(nib * 17);            /* 0-15 -> 0-255 */
	}
	return prev_line;
}

static void send_plane(u8 plane)
{
	u16 offset = 0;

	while (offset < DEPTH_FRAME_PIXELS) {
		u16 n = DEPTH_FRAME_PIXELS - offset;
		if (n > DEPTH_CHUNK_PIXELS) {
			n = DEPTH_CHUNK_PIXELS;
		}

		struct pbuf *p = pbuf_alloc(PBUF_TRANSPORT,
		                            sizeof(depth_chunk_hdr_t) + n, PBUF_RAM);
		if (!p) {
			xil_printf("depth_stream: pbuf_alloc failed, dropping rest of frame\r\n");
			return;
		}

		depth_chunk_hdr_t hdr;
		hdr.frame_id    = frame_id;
		hdr.chunk_index = offset;
		hdr.plane       = plane;
		hdr.reserved    = 0;
		hdr.reserved2   = 0;
		memcpy(p->payload, &hdr, sizeof(hdr));
		memcpy((u8 *)p->payload + sizeof(hdr), plane_chunk(plane, offset, n), n);

		if (udp_send(tx_pcb, p) != ERR_OK) {
			xil_printf("depth_stream: udp_send failed\r\n");
		}
		pbuf_free(p);

		offset += n;
	}
}

/* Streaming state machine.
 *
 * Two constraints shape this, and they pull in opposite directions:
 *
 *  - A readout must come from a FROZEN buffer. The cameras and the
 *    disparity engine write continuously; reading while they do splices
 *    strips from several frames into one image (visible as horizontal
 *    banding). So: arm, wait for all three buffers to report a whole
 *    frame captured, then read.
 *
 *  - Only ONE plane may be sent per pass through the main loop. Sending
 *    all three back-to-back triples the datagram burst, and the EmacPs
 *    driver's TX descriptor ring does not fail cleanly when overrun.
 *
 * Holding the freeze across several passes satisfies both, and has a nice
 * side effect: all three planes now come from the SAME instant, which is
 * what you want when comparing the two raw cameras against the depth map
 * they produced. */
/* Ethernet-camera build: both cameras, no depth plane.
 *
 * The wait condition is "both camera buffers ready" -- deliberately not
 * "all three", which is what the original stereo build used. The depth
 * buffer is not part of this stream, and including it meant that a single
 * buffer which never completed held up everything: the set never finished,
 * SNAP_WAIT_LIMIT expired, the freeze was released and re-armed, and not
 * one datagram was ever sent. That is exactly how this board presented as
 * "streams nothing" while the cameras were producing fine frames.
 *
 * Waiting for both cameras rather than each independently is what makes
 * the pair usable: they share one frame_id and one freeze, so the two
 * images come from the SAME instant. Streaming them independently would
 * be simpler but would hand the host two frames taken milliseconds apart,
 * which is useless for anything that compares them.
 *
 * Still one plane per pass through the main loop: sending both
 * back-to-back doubles the datagram burst, and the EmacPs TX descriptor
 * ring does not fail cleanly when overrun. */
enum { SNAP_IDLE, SNAP_WAIT, SNAP_SEND_DEPTH, SNAP_SEND_CAM1, SNAP_SEND_CAM2 };
static u8 snap_state = SNAP_IDLE;
static u32 snap_wait_polls;

/* If the buffers never report ready (e.g. a camera stops producing VSYNC)
 * this bounds the stall rather than wedging the stream forever. */
#define SNAP_WAIT_LIMIT 200000
/* Extra polls granted to the depth snapshot after both cameras are ready. */
#define DEPTH_GRACE_LIMIT (SNAP_WAIT_LIMIT / 4)
static u32 depth_grace_polls;

static void stream_step(void)
{
	switch (snap_state) {
	case SNAP_IDLE:
		cam_ctrl_snap_arm(1);
		snap_wait_polls = 0;
		depth_grace_polls = 0;
		snap_state = SNAP_WAIT;
		break;

	case SNAP_WAIT: {
		u32 ready = (cam_ctrl_status() >> STAT_SNAP_READY_SHIFT) & 0x7;
		if ((ready & STAT_SNAP_BOTH_CAMS) == STAT_SNAP_BOTH_CAMS) {
			/* The depth plane rides along with the camera pair. Its
			 * snapshot needs up to two engine frames (~33 ms) after
			 * arming, which is about as long as the cameras take, so
			 * the two finish in either order. Once the cameras are
			 * ready, give depth a short bounded grace period rather
			 * than dropping it half the time -- but it is still NOT
			 * part of the main wait condition: requiring all three is
			 * what once made a healthy board look dead, and the camera
			 * planes must keep flowing even if the depth engine stops. */
			if (ready & STAT_SNAP_DEPTH_READY) {
				snap_state = SNAP_SEND_DEPTH;
			} else if (++depth_grace_polls > DEPTH_GRACE_LIMIT) {
				snap_state = SNAP_SEND_CAM1;
			}
		} else if (++snap_wait_polls > SNAP_WAIT_LIMIT) {
			/* Give up on this set and retry rather than stalling. */
			cam_ctrl_snap_arm(0);
			snap_state = SNAP_IDLE;
		}
		break;
	}

	case SNAP_SEND_DEPTH:
		/* One byte per pixel straight from depth_engine_sad: the
		 * disparity itself (1..40), 0 = no answer. Same frame_id as the
		 * two camera planes that follow. */
		send_plane(PLANE_DEPTH);
		snap_state = SNAP_SEND_CAM1;
		break;

	case SNAP_SEND_CAM1:
		/* Both planes go out unconditionally: streaming the cameras is
		 * the whole point of this build, so they do not hang off
		 * preview_mask the way the optional stereo previews did. */
		send_plane(PLANE_CAM1);
		snap_state = SNAP_SEND_CAM2;
		break;

	case SNAP_SEND_CAM2:
		send_plane(PLANE_CAM2);
		/* Release the freeze so capture resumes. Both planes just sent
		 * share this frame_id, which is how the host knows they are a
		 * matched pair. */
		cam_ctrl_snap_arm(0);
		frame_id++;
		snap_state = SNAP_IDLE;
		break;

	default:
		snap_state = SNAP_IDLE;
		break;
	}
}

int transfer_data(void)
{
	/* The frame_done_toggle bit this used to poll only said "a disparity
	 * frame finished" -- it said nothing about the camera buffers, and the
	 * engine started overwriting immediately anyway. The snapshot handshake
	 * supersedes it: it reports when all three buffers hold a complete,
	 * frozen frame. */
	stream_step();
	return 0;
}
