import numpy as np

def quantize(tensor: np.ndarray, bit_width: int):
    """Computes symmetric quantization for hardware modeling."""
    max_val = np.max(np.abs(tensor))
    q_max = (2 ** (bit_width - 1)) - 1
    scale = max_val / q_max if max_val != 0 else 1.0
    quantized = np.round(tensor / scale)
    quantized = np.clip(quantized, -q_max, q_max).astype(np.int32)
    return quantized, float(scale), 0

def zrle_encode(q_data: np.ndarray) -> list:
    """Performs Zero Run-Length Encoding."""
    tokens = []
    if len(q_data) == 0:
        return tokens
    
    flat_data = q_data.flatten()
    i = 0
    n = len(flat_data)
    
    while i < n:
        if flat_data[i] == 0:
            zero_count = 0
            while i < n and flat_data[i] == 0:
                zero_count += 1
                i += 1
            tokens.append(("ZERO_RUN", zero_count))
        else:
            tokens.append(("VAL", int(flat_data[i])))
            i += 1
    return tokens

if __name__ == "__main__":
    # Test tensor
    test_tensor = np.array(
        [0.73, -0.15, 0.92, 0.0, -0.88, 0.44, 0.05, -0.02, 0.0, 0.0],
        dtype=np.float32,
    )
    
    print("=== Golden Reference Generation ===")
    print(f"Tensor: {test_tensor.tolist()}")
    
    # Quantize
    bit_width = 8
    quantized_data, scale, zero_point = quantize(test_tensor, bit_width)
    
    print(f"Scale: {scale:.6f}")
    print(f"Quantized: {quantized_data.tolist()}")
    
    # ZRLE Encode
    tokens = zrle_encode(quantized_data)
    print(f"Tokens: {tokens}")
    
    # Write quantized_golden.mem (8-bit hex)
    with open("quantized_golden.mem", "w") as f:
        for val in quantized_data:
            f.write(f"{val & 0xFF:02x}\n")
    print("\nGenerated: quantized_golden.mem")
    
    # Write zrle_golden.mem (9-bit hex, 3 digits)
    with open("zrle_golden.mem", "w") as f:
        for token_type, val in tokens:
            if token_type == "ZERO_RUN":
                hardware_token = (1 << 8) | (val & 0xFF)
            else:
                hardware_token = (0 << 8) | (val & 0xFF)
            f.write(f"{hardware_token:03x}\n")
    print("Generated: zrle_golden.mem")
    
    print("\nToken mapping:")
    for i, (token_type, val) in enumerate(tokens):
        if token_type == "ZERO_RUN":
            hw = (1 << 8) | val
            print(f"  [{i}] ZERO_RUN({val}) -> 0x{hw:03X}")
        else:
            hw = val & 0xFF
            print(f"  [{i}] VAL({val}) -> 0x{hw:03X}")