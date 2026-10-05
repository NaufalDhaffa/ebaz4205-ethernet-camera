/*
 * Run-time camera/stereo tuning over UDP.
 *
 * Replaces what the reference design did with five pushbuttons -- resend the
 * camera register table, and nudge the stereo rectification offsets while
 * watching the output. EBAZ4205 has no user buttons, so both live here, plus
 * arbitrary SCCB register access which the button design never had.
 */
#ifndef CAM_CTRL_H
#define CAM_CTRL_H

#include "xil_types.h"
#include "lwip/udp.h"

/* Control-channel bit layout in axi_gpio_ctrl's output register. Must match
 * hw/scripts/build_bd.tcl exactly. */
#define CTRL_RESEND_BIT       0
#define CTRL_ROW_OFFSET_SHIFT 1   /* 4 bits */
#define CTRL_COL_OFFSET_SHIFT 5   /* 8 bits */
#define CTRL_SCCB_EN_BIT      13
#define CTRL_SIOC_SHIFT       14  /* 2 bits, bit0=cam1 bit1=cam2 */
#define CTRL_SIOD_O_SHIFT     16  /* 2 bits */
#define CTRL_SIOD_OE_SHIFT    18  /* 2 bits */

/* Status register bits. */
#define STAT_CAM1_OK_BIT      0
#define STAT_CAM2_OK_BIT      1
#define STAT_FRAME_TOGGLE_BIT 2
#define STAT_SIOD_I_SHIFT     3   /* 2 bits */
#define STAT_SNAP_READY_SHIFT 5   /* 3 bits: [0]=cam1 [1]=cam2 [2]=depth */
#define STAT_SNAP_ALL_READY   0x7
#define STAT_SNAP_CAM1_READY  0x1
#define STAT_SNAP_CAM2_READY  0x2
#define STAT_SNAP_DEPTH_READY 0x4
#define STAT_SNAP_BOTH_CAMS   (STAT_SNAP_CAM1_READY | STAT_SNAP_CAM2_READY)

#define CTRL_SNAP_ARM_BIT     20
#define CTRL_LUMA_PHASE_BIT   23
#define CTRL_CAM_SWAP_BIT     24  /* depth engine: cam2 is the reference image */

/* UDP control protocol. Fixed 8-byte request and response so there is no
 * parsing ambiguity and a truncated datagram is simply rejected. */
#define CTRL_PORT     5002
#define CTRL_MAGIC0   'D'
#define CTRL_MAGIC1   'C'

enum {
    CMD_PING        = 0x00,
    CMD_SCCB_WRITE  = 0x01,  /* cam, reg, val            */
    CMD_SCCB_READ   = 0x02,  /* cam, reg        -> val   */
    CMD_SET_RECT    = 0x03,  /* cam = swap, row_offset (s4), col_offset (s8) */
    CMD_RESEND      = 0x04,  /* re-apply the register table */
    CMD_GET_STATUS  = 0x05,  /*                 -> status */
    CMD_SET_LUMA    = 0x07,  /* arg0 = luma_phase bit (which YUV422 byte is kept) */
    CMD_SET_PLANES  = 0x06,  /* arg0 = preview mask, bit0=cam1 bit1=cam2 */
};

enum {
    ST_OK        = 0,
    ST_BAD_MAGIC = 1,
    ST_BAD_CMD   = 2,
    ST_NO_ACK    = 3,   /* camera did not acknowledge on SCCB */
};

typedef struct __attribute__((packed)) {
    u8  magic0, magic1;
    u8  cmd;
    u8  cam;        /* 0 = camera 1, 1 = camera 2 */
    u8  arg0;
    u8  arg1;
    u16 seq;
} ctrl_req_t;

typedef struct __attribute__((packed)) {
    u8  magic0, magic1;
    u8  cmd;
    u8  status;
    u8  value;
    u8  pad;
    u16 seq;
} ctrl_rsp_t;

int  cam_ctrl_start(void);
void cam_ctrl_snap_arm(int on);
u32  cam_ctrl_status(void);
void cam_ctrl_apply_rect(u8 row_offset, u8 col_offset, u8 swap);

#endif /* CAM_CTRL_H */
