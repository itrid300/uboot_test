/*
 * Andes ATCSPI200 SPI controller
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */

#ifndef HW_SSI_ATCSPI200_H
#define HW_SSI_ATCSPI200_H

#include "hw/sysbus.h"
#include "hw/ssi/ssi.h"
#include "qemu/fifo32.h"
#include "qom/object.h"

#define TYPE_ATCSPI200 "atcspi200"
OBJECT_DECLARE_SIMPLE_TYPE(ATCSPI200State, ATCSPI200)

#define ATCSPI200_REG_SIZE      0x80
#define ATCSPI200_NUM_REGS      (ATCSPI200_REG_SIZE / 4)

typedef enum {
    ATCSPI200_PH_CMD = 0,
    ATCSPI200_PH_ADDR,
    ATCSPI200_PH_TOKEN,
    ATCSPI200_PH_FIRST,     /* first data phase of TransMode */
    ATCSPI200_PH_DUMMY,
    ATCSPI200_PH_SECOND,    /* second data phase of TransMode */
    ATCSPI200_PH_DONE,
} ATCSPI200Phase;

struct ATCSPI200State {
    SysBusDevice parent_obj;

    MemoryRegion mmio;
    qemu_irq irq;
    qemu_irq cs_line;
    SSIBus *bus;

    uint32_t regs[ATCSPI200_NUM_REGS];

    Fifo32 tx_fifo;
    Fifo32 rx_fifo;
    uint32_t fifo_depth;        /* property: entries, power of two 2..128 */

    /* transfer engine */
    bool active;
    uint32_t phase;
    uint32_t phase_left;        /* data units / bytes left in phase */
    uint32_t tx_word;           /* data-merge: current TX word */
    uint32_t tx_word_left;      /* bytes still to send from tx_word */
    uint32_t rx_word;           /* data-merge: RX bytes being coalesced */
    uint32_t rx_word_cnt;
};

#endif
