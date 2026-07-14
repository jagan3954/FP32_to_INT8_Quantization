# a.py
import math
import os

def round_half_away_from_zero(x):
    if x >= 0:
        return int(math.floor(x + 0.5))
    else:
        return int(math.ceil(x - 0.5))

def round_half_up(x):
    return int(math.floor(x + 0.5))

def hardware_exact_quantize_pipeline(float_tensor):
    raw_ints = [round_half_away_from_zero(val * (2**24)) for val in float_tensor]
    if not raw_ints: return [], []
        
    abs_max_raw = max(abs(x) for x in raw_ints)
    divisor = 127
    scale_raw = round_half_up(abs_max_raw / divisor)
    
    quantized_elements = []
    for data_raw in raw_ints:
        if scale_raw == 0:
            q_val = 0
        else:
            mag_data = abs(data_raw)
            mag_scale = abs(scale_raw)
            quotient = mag_data // mag_scale
            remainder = mag_data % mag_scale
            if (2 * remainder) >= mag_scale:
                quotient += 1
            q_val = quotient if data_raw >= 0 else -quotient
            
        if q_val > 127:  q_val = 127
        if q_val < -127: q_val = -127
        quantized_elements.append(q_val)
        
    tokens = []
    zero_run = 0
    for q_data in quantized_elements:
        if q_data == 0:
            zero_run += 1
            if zero_run == 255:
                tokens.append(0x1FF)
                zero_run = 0
        else:
            while zero_run > 0:
                if zero_run > 255:
                    tokens.append(0x1FF)
                    zero_run -= 255
                else:
                    tokens.append(0x100 | zero_run)
                    zero_run = 0
            tokens.append(q_data & 0xFF)
            
    while zero_run > 0:
        if zero_run > 255:
            tokens.append(0x1FF)
            zero_run -= 255
        else:
            tokens.append(0x100 | zero_run)
            zero_run = 0
            
    # Convert raw Q8.24 inputs back to hex strings for Vivado simulation input mapping
    input_hex_lines = [f"{x & 0xFFFFFFFF:08x}" for x in raw_ints]
    return input_hex_lines, tokens

if __name__ == "__main__":
    # Your Vivado simulation path from the error log
   
   
   
   # vivado_sim_path = "/home/skywalker/rtl/rtl-projects/quantixation/vivado/vivado.sim/sim_1/behav/xsim/"
    vivado_sim_path = "/home/skywalker/rtl/rtl-projects/quantixation/python"
    
    
    
    # Let's create an input test tensor (exactly 64 values long to match GOLDEN_TOKEN_COUNT in testbench)
    test_tensor = [0.12, -0.43, 0.0, 0.0, 0.0, 0.99, -1.2, 0.0] * 8
    
    input_hex, token_stream = hardware_exact_quantize_pipeline(test_tensor)
    
    # 1. Write the input tensor file
    with open(os.path.join(vivado_sim_path, "tensor_data.hex"), "w") as f:
        for line in input_hex:
            f.write(f"{line}\n")
            
    # 2. Write the golden comparison results file
    with open(os.path.join(vivado_sim_path, "golden_tokens.hex"), "w") as f:
        for tok in token_stream:
            f.write(f"{tok:03x}\n")
            
    print(f"Successfully generated matrix files inside: {vivado_sim_path}")
