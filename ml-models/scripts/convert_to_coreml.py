#!/usr/bin/env python3
"""
Convert DeepFilterNet3 PyTorch model to Core ML format.

This script loads a pretrained DeepFilterNet3 model and attempts to convert it
to Core ML format for use in the Vocana macOS application.
"""

import os
import sys
import torch
import coremltools as ct
import numpy as np
from pathlib import Path

# Add DeepFilterNet to path
sys.path.insert(0, str(Path(__file__).parent.parent / "DeepFilterNet" / "DeepFilterNet"))

from df.enhance import init_df
from df.model import ModelParams
from libdf import DF


def convert_model(model_dir: str, output_path: str):
    """
    Convert DeepFilterNet3 model to Core ML.
    
    Args:
        model_dir: Path to the pretrained model directory
        output_path: Path where the .mlpackage will be saved
    """
    print(f"Loading model from {model_dir}...")
    
    # Initialize model
    model, df_state, suffix, epoch = init_df(
        model_base_dir=model_dir,
        post_filter=False,
        log_level="WARNING",
        log_file=None,
        config_allow_defaults=True,
        epoch="best"
    )
    
    # Set to eval mode
    model.eval()
    model.to("cpu")
    
    # Get model parameters
    p = ModelParams()
    print(f"Model sample rate: {p.sr} Hz")
    print(f"FFT size: {p.fft_size}")
    print(f"Hop size: {p.hop_size}")
    print(f"ERB bands: {p.nb_erb}")
    print(f"DF bands: {p.nb_df}")
    print(f"Model loaded from epoch {epoch}")
    
    # Create example input
    # For a 32ms window at 48kHz: 48000 * 0.032 = 1536 samples
    batch_size = 1
    num_samples = p.fft_size * 2  # Use 2 frames for testing
    
    print(f"\nCreating example input with shape: [{batch_size}, {num_samples}]")
    example_input = torch.randn(batch_size, num_samples)
    
    # Trace the model
    print("\nTracing model with example input...")
    try:
        with torch.no_grad():
            traced_model = torch.jit.trace(model, example_input)
            print("Model traced successfully!")
    except Exception as e:
        print(f"Error during tracing: {e}")
        print("\nNote: DeepFilterNet uses complex operations that may not be directly traceable.")
        print("We may need to create a simplified wrapper model.")
        return False
    
    # Convert to Core ML
    print("\nConverting to Core ML...")
    try:
        # Define input shape
        input_shape = ct.Shape(shape=(1, ct.RangeDim(p.hop_size, num_samples * 10)))
        
        mlmodel = ct.convert(
            traced_model,
            inputs=[ct.TensorType(name="audio", shape=input_shape)],
            outputs=[ct.TensorType(name="enhanced_audio")],
            minimum_deployment_target=ct.target.macOS13,
            compute_units=ct.ComputeUnit.ALL,  # Use Neural Engine if available
        )
        
        # Add metadata
        mlmodel.author = "Vocana (DeepFilterNet by Rikorose)"
        mlmodel.license = "MIT/Apache-2.0"
        mlmodel.short_description = "Deep learning-based noise suppression"
        mlmodel.version = f"3.0.{epoch}"
        
        # Save the model
        print(f"\nSaving Core ML model to {output_path}...")
        mlmodel.save(output_path)
        print(f"Model saved successfully!")
        
        # Print model info
        print("\n=== Model Information ===")
        print(f"Input: audio waveform (1D tensor)")
        print(f"Output: enhanced audio waveform (1D tensor)")
        print(f"Minimum macOS version: 13.0")
        print(f"Compute units: All (CPU + GPU + Neural Engine)")
        
        return True
        
    except Exception as e:
        print(f"\nError during Core ML conversion: {e}")
        print("\nThis is expected - DeepFilterNet uses custom operations not supported by Core ML.")
        print("We need to implement a custom wrapper or use ONNX as an intermediate format.")
        return False


if __name__ == "__main__":
    # Paths
    script_dir = Path(__file__).parent
    model_dir = script_dir.parent / "pretrained" / "DeepFilterNet3"
    output_path = script_dir.parent / "coreml" / "DeepFilterNet3.mlpackage"
    
    # Create output directory
    output_path.parent.mkdir(parents=True, exist_ok=True)
    
    print("=" * 60)
    print("DeepFilterNet3 to Core ML Conversion")
    print("=" * 60)
    
    success = convert_model(str(model_dir), str(output_path))
    
    if success:
        print("\n✅ Conversion completed successfully!")
        sys.exit(0)
    else:
        print("\n❌ Conversion failed - see notes above")
        sys.exit(1)
