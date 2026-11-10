/*
 * Andes ATCSPI200 SPI controller (master mode, single I/O)
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 *
 * Register layout (APB, 32-bit registers):
 *   0x00 IdRev      0x10 TransFmt   0x14 DirectIO   0x20 TransCtrl
 *   0x24 Cmd        0x28 Addr       0x2C Data       0x30 Ctrl
 *   0x34 Status     0x38 IntrEn     0x3C IntrSt     0x40 Timing
 *   0x50 MemCtrl    0x60 SlvSt      0x64 SlvDataCnt 0x7C Config
 *
 * A transfer is started by writing the Cmd register.  The chip select is
 * asserted for the whole transaction, which consists of an optional command
 * phase (CmdEn), an optional address phase (AddrEn, AddrLen+1 bytes), an
 * optional token byte, and the data/dummy phases selected by TransMode.
 * Write data is taken from the TX FIFO and read data pushed to the RX FIFO;
 * when the TX FIFO is empty (write phase) or the RX FIFO is full (read
 * phase) the transfer stalls until software services the FIFO, exactly as
 * the hardware holds SCLK.  The serial clock is modelled as infinitely fast,
 * i.e. everything that can be shifted is shifted immediately.
 *
 * Not modelled: slave mode, DMA handshaking, Direct I/O, the AHB/EILM memory
 * mapped read window (MemCtrl is storage only), dual/quad wire timing (data
 * is still exchanged byte-wise, which is what m25p80 expects).
 */

#include "qemu/osdep.h"
#include "qemu/log.h"
#include "qemu/module.h"
#include "qapi/error.h"
#include "hw/irq.h"
#include "hw/qdev-properties.h"
#include "hw/ssi/atcspi200.h"
#include "migration/vmstate.h"

#define A_IDREV         0x00
#define A_TRANSFMT      0x10
#define A_DIRECTIO      0x14
#define A_TRANSCTRL     0x20
#define A_CMD           0x24
#define A_ADDR          0x28
#define A_DATA          0x2C
#define A_CTRL          0x30
#define A_STATUS        0x34
#define A_INTREN        0x38
#define A_INTRST        0x3C
#define A_TIMING        0x40
#define A_MEMCTRL       0x50
#define A_SLVST         0x60
#define A_SLVDATACNT    0x64
#define A_CONFIG        0x7C

#define R(a)            ((a) / 4)

#define IDREV_VALUE             0x02002000u

/* TransFmt */
#define FMT_CPHA                (1u << 0)
#define FMT_CPOL                (1u << 1)
#define FMT_SLVMODE             (1u << 2)
#define FMT_LSB                 (1u << 3)
#define FMT_MOSIBIDIR           (1u << 4)
#define FMT_DATAMERGE           (1u << 7)
#define FMT_DATALEN(v)          (((v) >> 8) & 0x1f)
#define FMT_ADDRLEN(v)          (((v) >> 16) & 0x3)
#define FMT_RESET               0x00020780u
#define FMT_MASK                0x00031f9fu

/* TransCtrl */
#define TC_RDCNT(v)             ((v) & 0x1ff)
#define TC_DUMMYCNT(v)          (((v) >> 9) & 0x3)
#define TC_TOKENVALUE           (1u << 11)
#define TC_WRCNT(v)             (((v) >> 12) & 0x1ff)
#define TC_TOKENEN              (1u << 21)
#define TC_DUALQUAD(v)          (((v) >> 22) & 0x3)
#define TC_TRANSMODE(v)         (((v) >> 24) & 0xf)
#define TC_ADDRFMT              (1u << 28)
#define TC_ADDREN               (1u << 29)
#define TC_CMDEN                (1u << 30)

/* Ctrl */
#define CTRL_SPIRST             (1u << 0)
#define CTRL_RXFIFORST          (1u << 1)
#define CTRL_TXFIFORST          (1u << 2)
#define CTRL_RXDMAEN            (1u << 3)
#define CTRL_TXDMAEN            (1u << 4)
#define CTRL_RXTHRES(v)         (((v) >> 8) & 0xff)
#define CTRL_TXTHRES(v)         (((v) >> 16) & 0xff)
#define CTRL_MASK               0x00ffff18u

/* Status */
#define ST_SPIACTIVE            (1u << 0)
#define ST_RXEMPTY              (1u << 14)
#define ST_RXFULL               (1u << 15)
#define ST_TXEMPTY              (1u << 22)
#define ST_TXFULL               (1u << 23)

/* IntrEn / IntrSt */
#define INT_RXFIFOOR            (1u << 0)
#define INT_TXFIFOUR            (1u << 1)
#define INT_RXFIFO              (1u << 2)
#define INT_TXFIFO              (1u << 3)
#define INT_END                 (1u << 4)
#define INT_SLVCMD              (1u << 5)
#define INT_MASK                0x3fu

/* TransMode */
enum {
    TM_WR_SYNC = 0, TM_WO, TM_RO, TM_WR, TM_RW, TM_WDR, TM_RDW,
    TM_NONE, TM_DW, TM_DR,
};

typedef enum { K_SKIP, K_W, K_R, K_WR } DataKind;

static uint8_t bitrev8(uint8_t b)
{
    b = (b & 0xf0) >> 4 | (b & 0x0f) << 4;
    b = (b & 0xcc) >> 2 | (b & 0x33) << 2;
    b = (b & 0xaa) >> 1 | (b & 0x55) << 1;
    return b;
}

static bool atcspi200_merge(ATCSPI200State *s)
{
    uint32_t fmt = s->regs[R(A_TRANSFMT)];
    return (fmt & FMT_DATAMERGE) && FMT_DATALEN(fmt) == 7;
}

/* bytes on the wire per FIFO data unit (merge mode: per byte) */
static unsigned atcspi200_unit_bytes(ATCSPI200State *s)
{
    if (atcspi200_merge(s)) {
        return 1;
    }
    return DIV_ROUND_UP(FMT_DATALEN(s->regs[R(A_TRANSFMT)]) + 1, 8);
}

static uint32_t atcspi200_unit_mask(ATCSPI200State *s)
{
    unsigned bits = FMT_DATALEN(s->regs[R(A_TRANSFMT)]) + 1;
    return bits >= 32 ? 0xffffffffu : (1u << bits) - 1;
}

static uint8_t atcspi200_xfer_byte(ATCSPI200State *s, uint8_t out)
{
    bool lsb = s->regs[R(A_TRANSFMT)] & FMT_LSB;
    uint8_t in;

    in = ssi_transfer(s->bus, lsb ? bitrev8(out) : out);
    return lsb ? bitrev8(in) : in;
}

/* Exchange one data unit (non-merge mode) */
static uint32_t atcspi200_xfer_unit(ATCSPI200State *s, uint32_t out)
{
    unsigned n = atcspi200_unit_bytes(s);
    bool lsb = s->regs[R(A_TRANSFMT)] & FMT_LSB;
    uint32_t in = 0;
    unsigned i;

    for (i = 0; i < n; i++) {
        unsigned sh = lsb ? 8 * i : 8 * (n - 1 - i);
        in |= (uint32_t)atcspi200_xfer_byte(s, out >> sh) << sh;
    }
    return in & atcspi200_unit_mask(s);
}

/* What the data phase @ph does for the current TransMode, and its length */
static DataKind atcspi200_data_kind(ATCSPI200State *s, int ph, uint32_t *cnt)
{
    uint32_t tc = s->regs[R(A_TRANSCTRL)];
    uint32_t wr = TC_WRCNT(tc) + 1, rd = TC_RDCNT(tc) + 1;
    DataKind first = K_SKIP, second = K_SKIP;

    switch (TC_TRANSMODE(tc)) {
    case TM_WR_SYNC:
        first = K_WR;
        break;
    case TM_WO:
        first = K_W;
        break;
    case TM_RO:
        first = K_R;
        break;
    case TM_WR:
    case TM_WDR:
        first = K_W;
        second = K_R;
        break;
    case TM_RW:
    case TM_RDW:
        first = K_R;
        second = K_W;
        break;
    case TM_DW:
        second = K_W;
        break;
    case TM_DR:
        second = K_R;
        break;
    default:
        break;
    }

    if (ph == ATCSPI200_PH_FIRST) {
        *cnt = first == K_R ? rd : wr;
        return first;
    }
    *cnt = second == K_R ? rd : wr;
    return second;
}

static bool atcspi200_phase_present(ATCSPI200State *s, int ph)
{
    uint32_t tc = s->regs[R(A_TRANSCTRL)];
    uint32_t mode = TC_TRANSMODE(tc);
    uint32_t cnt;

    switch (ph) {
    case ATCSPI200_PH_CMD:
        return tc & TC_CMDEN;
    case ATCSPI200_PH_ADDR:
        return tc & TC_ADDREN;
    case ATCSPI200_PH_TOKEN:
        /* token follows the address phase of read transfers */
        return (tc & TC_TOKENEN) &&
               (mode == TM_RO || mode == TM_RW || mode == TM_RDW ||
                mode == TM_DR);
    case ATCSPI200_PH_DUMMY:
        return mode == TM_WDR || mode == TM_RDW || mode == TM_DW ||
               mode == TM_DR;
    case ATCSPI200_PH_FIRST:
    case ATCSPI200_PH_SECOND:
        return atcspi200_data_kind(s, ph, &cnt) != K_SKIP;
    default:
        return false;
    }
}

static void atcspi200_update_irq(ATCSPI200State *s)
{
    uint32_t rxn = fifo32_num_used(&s->rx_fifo);
    uint32_t txn = fifo32_num_used(&s->tx_fifo);
    uint32_t ctrl = s->regs[R(A_CTRL)];

    /* threshold events latch into IntrSt (W1C) while the condition holds */
    if (rxn && rxn >= CTRL_RXTHRES(ctrl)) {
        s->regs[R(A_INTRST)] |= INT_RXFIFO;
    }
    if (s->active && txn <= CTRL_TXTHRES(ctrl)) {
        s->regs[R(A_INTRST)] |= INT_TXFIFO;
    }
    qemu_set_irq(s->irq,
                 !!(s->regs[R(A_INTRST)] & s->regs[R(A_INTREN)] & INT_MASK));
}

static void atcspi200_end(ATCSPI200State *s)
{
    s->active = false;
    s->phase = ATCSPI200_PH_DONE;
    s->tx_word_left = 0;
    s->rx_word_cnt = 0;
    qemu_set_irq(s->cs_line, 1);
}

static void atcspi200_next_phase(ATCSPI200State *s)
{
    uint32_t tc = s->regs[R(A_TRANSCTRL)];
    uint32_t cnt;

    do {
        s->phase++;
    } while (s->phase < ATCSPI200_PH_DONE &&
             !atcspi200_phase_present(s, s->phase));

    switch (s->phase) {
    case ATCSPI200_PH_FIRST:
    case ATCSPI200_PH_SECOND:
        atcspi200_data_kind(s, s->phase, &cnt);
        s->phase_left = cnt;
        break;
    case ATCSPI200_PH_DUMMY:
        s->phase_left = (TC_DUMMYCNT(tc) + 1) * atcspi200_unit_bytes(s);
        break;
    default:
        s->phase_left = 0;
        break;
    }
}

static void atcspi200_rx_push(ATCSPI200State *s, uint32_t v)
{
    fifo32_push(&s->rx_fifo, v);
}

/* Run the transfer engine until it finishes or stalls on a FIFO. */
static void atcspi200_run(ATCSPI200State *s)
{
    while (s->active) {
        uint32_t tc = s->regs[R(A_TRANSCTRL)];
        bool merge = atcspi200_merge(s);
        uint32_t cnt;
        DataKind kind;
        int i;

        switch (s->phase) {
        case ATCSPI200_PH_CMD:
            atcspi200_xfer_byte(s, s->regs[R(A_CMD)] & 0xff);
            atcspi200_next_phase(s);
            continue;
        case ATCSPI200_PH_ADDR:
            for (i = FMT_ADDRLEN(s->regs[R(A_TRANSFMT)]); i >= 0; i--) {
                atcspi200_xfer_byte(s, s->regs[R(A_ADDR)] >> (8 * i));
            }
            atcspi200_next_phase(s);
            continue;
        case ATCSPI200_PH_TOKEN:
            atcspi200_xfer_byte(s, (tc & TC_TOKENVALUE) ? 0x69 : 0x00);
            atcspi200_next_phase(s);
            continue;
        case ATCSPI200_PH_DUMMY:
            while (s->phase_left) {
                atcspi200_xfer_byte(s, 0);
                s->phase_left--;
            }
            atcspi200_next_phase(s);
            continue;
        case ATCSPI200_PH_FIRST:
        case ATCSPI200_PH_SECOND:
            break;
        default:
            atcspi200_end(s);
            s->regs[R(A_INTRST)] |= INT_END;
            return;
        }

        if (!s->phase_left) {
            atcspi200_next_phase(s);
            continue;
        }

        kind = atcspi200_data_kind(s, s->phase, &cnt);
        if ((kind == K_R || kind == K_WR) && fifo32_is_full(&s->rx_fifo)) {
            return;                             /* wait for RX FIFO space */
        }

        if (merge) {
            uint8_t out = 0, in;

            if (kind == K_W || kind == K_WR) {
                if (!s->tx_word_left) {
                    if (fifo32_is_empty(&s->tx_fifo)) {
                        return;                 /* wait for TX data */
                    }
                    s->tx_word = fifo32_pop(&s->tx_fifo);
                    s->tx_word_left = 4;
                }
                out = s->tx_word >> (8 * (4 - s->tx_word_left));
                s->tx_word_left--;
            }
            in = atcspi200_xfer_byte(s, out);
            s->phase_left--;
            if (!s->phase_left) {
                s->tx_word_left = 0;            /* unused bytes dropped */
            }
            if (kind == K_R || kind == K_WR) {
                s->rx_word |= (uint32_t)in << (8 * s->rx_word_cnt);
                s->rx_word_cnt++;
                if (s->rx_word_cnt == 4 || !s->phase_left) {
                    atcspi200_rx_push(s, s->rx_word);
                    s->rx_word = 0;
                    s->rx_word_cnt = 0;
                }
            }
        } else {
            uint32_t out = 0, in;

            if (kind == K_W || kind == K_WR) {
                if (fifo32_is_empty(&s->tx_fifo)) {
                    return;                     /* wait for TX data */
                }
                out = fifo32_pop(&s->tx_fifo);
            }
            in = atcspi200_xfer_unit(s, out);
            s->phase_left--;
            if (kind == K_R || kind == K_WR) {
                atcspi200_rx_push(s, in);
            }
        }
    }
}

static void atcspi200_start(ATCSPI200State *s)
{
    uint32_t tc = s->regs[R(A_TRANSCTRL)];

    if (s->regs[R(A_TRANSFMT)] & FMT_SLVMODE) {
        qemu_log_mask(LOG_UNIMP, "atcspi200: slave mode not supported\n");
        return;
    }
    if (s->active) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "atcspi200: Cmd written while a transfer is active\n");
        return;
    }
    if (TC_TRANSMODE(tc) > TM_DR) {
        qemu_log_mask(LOG_GUEST_ERROR, "atcspi200: reserved TransMode %u\n",
                      TC_TRANSMODE(tc));
    }
    if (TC_DUALQUAD(tc) || (tc & TC_ADDRFMT)) {
        qemu_log_mask(LOG_UNIMP,
                      "atcspi200: dual/quad I/O modelled as single I/O\n");
    }
    if (TC_TRANSMODE(tc) == TM_WR_SYNC && TC_WRCNT(tc) != TC_RDCNT(tc)) {
        qemu_log_mask(LOG_GUEST_ERROR,
                      "atcspi200: WR_SYNC with WrTranCnt != RdTranCnt\n");
    }

    s->active = true;
    s->tx_word_left = 0;
    s->rx_word = 0;
    s->rx_word_cnt = 0;
    s->phase = ATCSPI200_PH_CMD;
    qemu_set_irq(s->cs_line, 0);
    if (!atcspi200_phase_present(s, s->phase)) {
        atcspi200_next_phase(s);
    }
    atcspi200_run(s);
}

static void atcspi200_abort(ATCSPI200State *s)
{
    if (s->active) {
        atcspi200_end(s);
    }
}

static uint64_t atcspi200_read(void *opaque, hwaddr addr, unsigned size)
{
    ATCSPI200State *s = ATCSPI200(opaque);
    uint32_t v = 0, n;

    switch (addr) {
    case A_IDREV:
    case A_TRANSFMT:
    case A_DIRECTIO:
    case A_TRANSCTRL:
    case A_CMD:
    case A_ADDR:
    case A_CTRL:
    case A_INTREN:
    case A_INTRST:
    case A_TIMING:
    case A_MEMCTRL:
    case A_CONFIG:
        v = s->regs[R(addr)];
        break;
    case A_DATA:
        if (fifo32_is_empty(&s->rx_fifo)) {
            qemu_log_mask(LOG_GUEST_ERROR, "atcspi200: RX FIFO underflow\n");
            break;
        }
        v = fifo32_pop(&s->rx_fifo);
        atcspi200_run(s);
        atcspi200_update_irq(s);
        break;
    case A_STATUS:
        n = fifo32_num_used(&s->rx_fifo);
        v |= (n & 0x1f) << 8 | ((n >> 5) & 0x3) << 24;
        v |= fifo32_is_empty(&s->rx_fifo) ? ST_RXEMPTY : 0;
        v |= fifo32_is_full(&s->rx_fifo) ? ST_RXFULL : 0;
        n = fifo32_num_used(&s->tx_fifo);
        v |= (n & 0x1f) << 16 | ((n >> 5) & 0x3) << 28;
        v |= fifo32_is_empty(&s->tx_fifo) ? ST_TXEMPTY : 0;
        v |= fifo32_is_full(&s->tx_fifo) ? ST_TXFULL : 0;
        v |= s->active ? ST_SPIACTIVE : 0;
        break;
    case A_SLVST:
    case A_SLVDATACNT:
        break;
    default:
        qemu_log_mask(LOG_GUEST_ERROR,
                      "atcspi200: bad read offset 0x%" HWADDR_PRIx "\n", addr);
        break;
    }
    return v;
}

static void atcspi200_write(void *opaque, hwaddr addr, uint64_t val64,
                            unsigned size)
{
    ATCSPI200State *s = ATCSPI200(opaque);
    uint32_t val = val64;

    switch (addr) {
    case A_TRANSFMT:
        if (val & FMT_SLVMODE) {
            qemu_log_mask(LOG_UNIMP, "atcspi200: slave mode not supported\n");
        }
        s->regs[R(addr)] = val & FMT_MASK;
        break;
    case A_DIRECTIO:
        if (val & (1u << 24)) {
            qemu_log_mask(LOG_UNIMP, "atcspi200: direct I/O not supported\n");
        }
        s->regs[R(addr)] = val & 0x013f3f3fu;
        break;
    case A_TRANSCTRL:
        s->regs[R(addr)] = val & 0x7fffffffu;   /* SlvDataOnly unsupported */
        break;
    case A_CMD:
        s->regs[R(addr)] = val & 0xff;
        atcspi200_start(s);
        break;
    case A_ADDR:
        s->regs[R(addr)] = val;
        break;
    case A_DATA:
        if (fifo32_is_full(&s->tx_fifo)) {
            qemu_log_mask(LOG_GUEST_ERROR, "atcspi200: TX FIFO overflow\n");
            break;
        }
        fifo32_push(&s->tx_fifo,
                    atcspi200_merge(s) ? val : val & atcspi200_unit_mask(s));
        atcspi200_run(s);
        break;
    case A_CTRL:
        if (val & (CTRL_RXDMAEN | CTRL_TXDMAEN)) {
            qemu_log_mask(LOG_UNIMP, "atcspi200: DMA not supported\n");
        }
        if (val & CTRL_SPIRST) {
            atcspi200_abort(s);
        }
        if (val & CTRL_RXFIFORST) {
            fifo32_reset(&s->rx_fifo);
        }
        if (val & CTRL_TXFIFORST) {
            fifo32_reset(&s->tx_fifo);
            s->tx_word_left = 0;
        }
        /* reset bits complete immediately and read back as 0 */
        s->regs[R(addr)] = val & CTRL_MASK;
        if (s->active) {
            atcspi200_run(s);
        }
        break;
    case A_INTREN:
        s->regs[R(addr)] = val & INT_MASK;
        break;
    case A_INTRST:
        s->regs[R(addr)] &= ~(val & INT_MASK);
        break;
    case A_TIMING:
        s->regs[R(addr)] = val & 0x3fffu;
        break;
    case A_MEMCTRL:
        s->regs[R(addr)] = val & 0xfu;
        break;
    case A_IDREV:
    case A_STATUS:
    case A_CONFIG:
    case A_SLVST:
    case A_SLVDATACNT:
        qemu_log_mask(LOG_GUEST_ERROR,
                      "atcspi200: write to read-only reg 0x%" HWADDR_PRIx "\n",
                      addr);
        break;
    default:
        qemu_log_mask(LOG_GUEST_ERROR,
                      "atcspi200: bad write offset 0x%" HWADDR_PRIx "\n", addr);
        break;
    }
    atcspi200_update_irq(s);
}

static const MemoryRegionOps atcspi200_ops = {
    .read = atcspi200_read,
    .write = atcspi200_write,
    .endianness = DEVICE_LITTLE_ENDIAN,
    .valid = {
        .min_access_size = 4,
        .max_access_size = 4,
    },
};

static void atcspi200_reset(DeviceState *dev)
{
    ATCSPI200State *s = ATCSPI200(dev);
    unsigned fifo_log = ctz32(s->fifo_depth) - 1;

    memset(s->regs, 0, sizeof(s->regs));
    s->regs[R(A_IDREV)] = IDREV_VALUE;
    s->regs[R(A_TRANSFMT)] = FMT_RESET;
    s->regs[R(A_CONFIG)] = fifo_log | fifo_log << 4;
    fifo32_reset(&s->tx_fifo);
    fifo32_reset(&s->rx_fifo);
    s->active = false;
    s->phase = ATCSPI200_PH_DONE;
    s->phase_left = 0;
    s->tx_word = 0;
    s->tx_word_left = 0;
    s->rx_word = 0;
    s->rx_word_cnt = 0;
    qemu_set_irq(s->cs_line, 1);
    qemu_set_irq(s->irq, 0);
}

static void atcspi200_realize(DeviceState *dev, Error **errp)
{
    ATCSPI200State *s = ATCSPI200(dev);
    SysBusDevice *sbd = SYS_BUS_DEVICE(dev);

    if (!is_power_of_2(s->fifo_depth) || s->fifo_depth < 2 ||
        s->fifo_depth > 128) {
        error_setg(errp, "atcspi200: fifo-depth must be a power of 2, 2..128");
        return;
    }

    s->bus = ssi_create_bus(dev, "spi");
    sysbus_init_irq(sbd, &s->irq);
    sysbus_init_irq(sbd, &s->cs_line);
    memory_region_init_io(&s->mmio, OBJECT(s), &atcspi200_ops, s,
                          TYPE_ATCSPI200, ATCSPI200_REG_SIZE);
    sysbus_init_mmio(sbd, &s->mmio);
    fifo32_create(&s->tx_fifo, s->fifo_depth);
    fifo32_create(&s->rx_fifo, s->fifo_depth);
}

static Property atcspi200_properties[] = {
    DEFINE_PROP_UINT32("fifo-depth", ATCSPI200State, fifo_depth, 16),
    DEFINE_PROP_END_OF_LIST(),
};

static const VMStateDescription vmstate_atcspi200 = {
    .name = TYPE_ATCSPI200,
    .version_id = 1,
    .minimum_version_id = 1,
    .fields = (const VMStateField[]) {
        VMSTATE_UINT32_ARRAY(regs, ATCSPI200State, ATCSPI200_NUM_REGS),
        VMSTATE_FIFO32(tx_fifo, ATCSPI200State),
        VMSTATE_FIFO32(rx_fifo, ATCSPI200State),
        VMSTATE_BOOL(active, ATCSPI200State),
        VMSTATE_UINT32(phase, ATCSPI200State),
        VMSTATE_UINT32(phase_left, ATCSPI200State),
        VMSTATE_UINT32(tx_word, ATCSPI200State),
        VMSTATE_UINT32(tx_word_left, ATCSPI200State),
        VMSTATE_UINT32(rx_word, ATCSPI200State),
        VMSTATE_UINT32(rx_word_cnt, ATCSPI200State),
        VMSTATE_END_OF_LIST()
    }
};

static void atcspi200_class_init(ObjectClass *klass, void *data)
{
    DeviceClass *dc = DEVICE_CLASS(klass);

    device_class_set_props(dc, atcspi200_properties);
    device_class_set_legacy_reset(dc, atcspi200_reset);
    dc->realize = atcspi200_realize;
    dc->vmsd = &vmstate_atcspi200;
}

static const TypeInfo atcspi200_info = {
    .name          = TYPE_ATCSPI200,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(ATCSPI200State),
    .class_init    = atcspi200_class_init,
};

static void atcspi200_register_types(void)
{
    type_register_static(&atcspi200_info);
}

type_init(atcspi200_register_types)
