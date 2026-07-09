import numpy as np


def quantize(tensor: np.ndarray, bit_width: int) -> (np.ndarray, float, int):
    """Computes symmetric quantization for hardware modeling.

    Returns (quantized int array, scale, zero_point=0).
    """
    # Calculate scale based on the absolute maximum value
    max_val = np.max(np.abs(tensor))
    q_max = (2 ** (bit_width - 1)) - 1

    # Avoid division by zero if the tensor is entirely zeros
    scale = max_val / q_max if max_val != 0 else 1.0

    # Quantize, round to nearest integer, and clip to symmetric limits
    quantized = np.round(tensor / scale)
    quantized = np.clip(quantized, -q_max, q_max).astype(np.int32)

    return quantized, float(scale), 0


def zrle_encode(q_data: np.ndarray) -> list:
    """Performs Zero Run-Length Encoding.

    Consecutive zeros become a single ("ZERO_RUN", count) token. Non-zero values
    become ("VAL", value) tokens.
    """
    tokens = []
    if len(q_data) == 0:
        return tokens

    flat_data = q_data.flatten()
    i = 0
    n = len(flat_data)

    while i < n:
        if flat_data[i] == 0:
            zero_count = 0
            # Count consecutive zeros, ensuring we handle hardware/protocol limits if any
            # (No explicit max run-length was requested, so it captures the full run)
            while i < n and flat_data[i] == 0:
                zero_count += 1
                i += 1
            tokens.append(("ZERO_RUN", zero_count))
        else:
            tokens.append(("VAL", int(flat_data[i])))
            i += 1

    return tokens


def zrle_decode(tokens: list) -> np.ndarray:
    """Reverses zrle_encode exactly for round-trip verification."""
    decoded_list = []
    for token_type, value in tokens:
        if token_type == "ZERO_RUN":
            decoded_list.extend([0] * value)
        elif token_type == "VAL":
            decoded_list.append(value)
    return np.array(decoded_list, dtype=np.int32)


def compression_ratio(original_size_bits: int, tokens: list) -> float:
    """Computes bits-before / bits-after compression ratio.

    Assumes 9 bits per token (1 flag bit + 8-bit payload).
    """
    compressed_size_bits = len(tokens) * 9
    if compressed_size_bits == 0:
        return 0.0
    return original_size_bits / compressed_size_bits


def to_hex_8bit(val: int) -> str:
    """Converts a signed integer to an 8-bit two's complement hex string."""
    return f"{(val & 0xFF):02x}"


if __name__ == "__main__":
    # --- 1. Define Test Tensor ---
    test_tensor = np.array(
        [0.73, -0.15, 0.92, 0.0, -0.88, 0.44, 0.05, -0.02, 0.0, 0.0],
        dtype=np.float32,
    )

    print("=== Hardware Quantization + Compression Golden Model ===")
    print(f"Original Tensor: {test_tensor}")
    print(f"Min Value:       {np.min(test_tensor)}")
    print(f"Max Value:       {np.max(test_tensor)}")
    print("-" * 60)

    # --- 2. Quantization (8-bit symmetric) ---
    bit_width = 8
    quantized_data, scale, zero_point = quantize(test_tensor, bit_width)

    print(f"Quantization Scale: {scale:.6f}")
    print(f"Zero Point:         {zero_point}")
    print(f"Quantized Array:    {quantized_data}")
    print("-" * 60)

    # --- 3. ZRLE Encoding ---
    tokens = zrle_encode(quantized_data)
    print("ZRLE Encoded Tokens:")
    for token in tokens:
        print(f"  {token}")
    print("-" * 60)

    # --- 4. Verification Check ---
    decoded_data = zrle_decode(tokens)
    is_match = np.array_equal(quantized_data, decoded_data)
    print(f"Round-Trip Verification: {'PASS' if is_match else 'FAIL'}")
    assert is_match, "CRITICAL: Decoded data does not match quantized data!"

    # --- 5. Compression Metrics ---
    # Original uncompressed size assumes 8 bits per literal value
    original_size_bits = len(quantized_data) * 8
    ratio = compression_ratio(original_size_bits, tokens)
    print(f"Original Size:       {original_size_bits} bits")
    print(f"Compressed Size:     {len(tokens) * 9} bits (9 bits per token)")
    print(f"Compression Ratio:   {ratio:.3f}x")
    print("-" * 60)

    # --- 6. Write Hardware Memory Files (.mem for $readmemh) ---

    # Write quantized array as 8-bit signed hex
    quantized_mem_file = "quantized_golden.mem"
    with open(quantized_mem_file, "w") as f:
        for val in quantized_data:
            f.write(f"{to_hex_8bit(val)}\n")
    print(f"Successfully generated: {quantized_mem_file}")

    # Write ZRLE tokens to file
    # Hardware Assumption for the 9-bit token mapping:
    # Flag bit (MSB): 1 = ZERO_RUN, 0 = VAL
    # Payload (8 LSBs): Count for runs, 8-bit signed two's complement for values
    zrle_mem_file = "zrle_golden.mem"
    with open(zrle_mem_file, "w") as f:
        for token_type, val in tokens:
            if token_type == "ZERO_RUN":
                # Flag bit = 1, combine with 8-bit payload
                hardware_token = (1 << 8) | (val & 0xFF)
            else:  # VAL
                # Flag bit = 0, combine with 8-bit signed payload
                hardware_token = (0 << 8) | (val & 0xFF)

            # Formatting as a 3-nibble hex string to accommodate the 9-bit value cleanly
            f.write(f"{hardware_token:03x}\n")
    print(f"Successfully generated: {zrle_mem_file}")
    print("========================================================")