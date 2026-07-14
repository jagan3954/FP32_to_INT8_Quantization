"""
quant_golden.py
Python golden reference model matching the FULL quant_pipeline_top.v
datapath bit-for-bit: stats -> precision_controller -> quant_engine ->
zrle_encoder. Produces the exact same 9-bit token stream m_tdata carries
on real hardware, and can diff it directly against output_tokens.hex
(the file your testbench's axis_slave_bfm already writes from the RTL run).

Stage 1 (quantization) mirrors precision_controller.v + quant_engine.v.
Stage 2 (compression) mirrors zrle_encoder.v:
    comp_data[8] = 0 -> literal token,  payload = signed 8-bit value
    comp_data[8] = 1 -> zero-run token, payload = run length 1..255
    (runs longer than 255 zeros are split into multiple 255-tokens,
     exactly as the FSM's FLUSH state does)

Usage:
    # quantization only (pre-compression):
    python quant_golden.py tensor_data.hex --mode int8 --out quantized_golden.mem

    # full pipeline incl. ZRLE, written as 9-bit hex tokens (3 hex digits):
    python quant_golden.py tensor_data.hex --mode int8 --compress --out zrle_golden.mem

    # full pipeline AND diff against the RTL sim's actual output:
    python quant_golden.py tensor_data.hex --mode int8 --compress \
        --compare output_tokens.hex
"""
import argparse


def to_signed32(x):
    x &= 0xFFFFFFFF
    return x - (1 << 32) if x & 0x80000000 else x


def mag32(v):
    return -v if v < 0 else v


def round_div(dividend_mag, divisor_mag):
    """floor division + round-half-away-from-zero on magnitudes -- exactly
    what the restoring divider + round_up logic computes in both
    precision_controller.v and quant_engine.v."""
    if divisor_mag == 0:
        return 0
    q, r = divmod(dividend_mag, divisor_mag)
    if 2 * r >= divisor_mag:
        q += 1
    return q


def compute_scale(min_val, max_val, mode):
    """Mirrors precision_controller.v S_IDLE -> S_COMPUTE -> S_DONE."""
    abs_max = max(mag32(min_val), mag32(max_val))
    if mode == 'int8':
        divisor, bit_width = 127, 8
    elif mode == 'int4':
        divisor, bit_width = 7, 4
    else:
        divisor, bit_width = 1, 0  # passthrough sentinel
    scale = round_div(abs_max, divisor)
    return scale, bit_width


def quantize_one(data_in, scale, bit_width, zero_point=0):
    """Mirrors quant_engine.v S_IDLE -> S_DIVIDE -> S_ROUND."""
    if data_in == 0 or scale == 0:
        q_mag, sign = 0, 1
    else:
        q_mag = round_div(mag32(data_in), mag32(scale))
        sign = -1 if (data_in < 0) ^ (scale < 0) else 1

    q = sign * q_mag + zero_point

    limit = 7 if bit_width == 4 else 127
    if q > limit:
        q = limit
    if q < -limit:
        q = -limit
    return q


def run_golden(tensor_raw, mode):
    min_val = min(tensor_raw)
    max_val = max(tensor_raw)
    scale, bit_width = compute_scale(min_val, max_val, mode)
    tokens = [quantize_one(v, scale, bit_width) for v in tensor_raw]
    return scale, bit_width, tokens


# ---------------------------------------------------------------------------
# ZRLE compression -- mirrors zrle_encoder.v exactly
# ---------------------------------------------------------------------------
def flush_run(zero_count):
    """One or more run-tokens, each capped at payload 255, exactly matching
    the FSM's FLUSH state: while remaining != 0, emit min(remaining, 255)."""
    out = []
    remaining = zero_count
    while remaining != 0:
        if remaining > 255:
            out.append((1, 255))
            remaining -= 255
        else:
            out.append((1, remaining))
            remaining = 0
    return out


def zrle_encode(q_tokens):
    """Mirrors zrle_encoder.v IDLE/ZEROS/FLUSH FSM over a full quantized
    token sequence. Returns a list of (flag, payload) pairs; combine as
    (flag << 8) | payload to get the 9-bit comp_data value."""
    out = []
    zero_count = 0
    n = len(q_tokens)
    for i, v in enumerate(q_tokens):
        last_in = (i == n - 1)
        if v == 0:
            zero_count += 1
            if last_in:
                out.extend(flush_run(zero_count))
                zero_count = 0
        else:
            if zero_count > 0:
                out.extend(flush_run(zero_count))
                zero_count = 0
            out.append((0, v & 0xFF))  # literal, sign-preserved as raw byte
    return out


def load_hex(path):
    with open(path) as f:
        return [to_signed32(int(line.strip(), 16)) for line in f if line.strip()]


def load_hex_raw(path):
    """Load a hex file without forcing 32-bit sign interpretation -- used
    for comparing against output_tokens.hex (9-bit tokens)."""
    with open(path) as f:
        return [int(line.strip(), 16) for line in f if line.strip()]


def save_hex(path, values, width_hex_digits=2):
    mask = (1 << (4 * width_hex_digits)) - 1
    with open(path, 'w') as f:
        for v in values:
            f.write(f"{v & mask:0{width_hex_digits}x}\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('input_hex', help='path to tensor_data.hex (same file the RTL testbench uses)')
    ap.add_argument('--mode', choices=['int8', 'int4', 'passthrough'], default='int8')
    ap.add_argument('--out', default='quantized_golden.mem', help='output .mem file')
    ap.add_argument('--compress', action='store_true',
                     help='also run ZRLE compression, matching zrle_encoder.v (full pipeline)')
    ap.add_argument('--compare', metavar='OUTPUT_TOKENS_HEX', default=None,
                     help='diff the ZRLE-compressed golden stream against the RTL sim output file '
                          '(e.g. output_tokens.hex written by axis_slave_bfm)')
    args = ap.parse_args()

    tensor = load_hex(args.input_hex)
    scale, bit_width, tokens = run_golden(tensor, args.mode)

    print(f"mode={args.mode}  scale_raw(Q8.24)={scale}  bit_width={bit_width}")
    print(f"n_quantized_tokens={len(tokens)}")
    print(f"first 10 quantized tokens: {tokens[:10]}")

    if not args.compress:
        save_hex(args.out, tokens, width_hex_digits=2)
        print(f"wrote {len(tokens)} quantized tokens to {args.out}")
        return

    comp = zrle_encode(tokens)
    comp_words = [(flag << 8) | payload for flag, payload in comp]
    save_hex(args.out, comp_words, width_hex_digits=3)
    print(f"n_compressed_tokens={len(comp_words)}")
    print(f"first 10 compressed tokens (hex): {[f'{w:03x}' for w in comp_words[:10]]}")
    print(f"wrote {len(comp_words)} compressed tokens to {args.out}")

    if args.compare:
        rtl_words = load_hex_raw(args.compare)
        print(f"\ncomparing against {args.compare} ({len(rtl_words)} RTL tokens)...")
        if len(rtl_words) != len(comp_words):
            print(f"  LENGTH MISMATCH: python={len(comp_words)} rtl={len(rtl_words)}")
        mismatches = 0
        n_check = min(len(rtl_words), len(comp_words))
        for i in range(n_check):
            if rtl_words[i] != comp_words[i]:
                mismatches += 1
                print(f"  MISMATCH tok {i}: python={comp_words[i]:03x} rtl={rtl_words[i]:03x}")
        if mismatches == 0 and len(rtl_words) == len(comp_words):
            print(f"  MATCH: all {n_check} tokens identical, Python == RTL")
        else:
            print(f"  {mismatches} mismatches out of {n_check} compared")


if __name__ == '__main__':
    main()