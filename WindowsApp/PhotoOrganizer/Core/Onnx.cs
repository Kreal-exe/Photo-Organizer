using Microsoft.ML.OnnxRuntime;

namespace PhotoOrganizer.Core;

/// <summary>Opening ONNX models on the graphics card (DirectML: any DirectX 12 card) or, without one, on the processor.</summary>
public static class Onnx
{
    public static (InferenceSession Session, bool Gpu) Open(byte[] model, bool gpu)
    {
        if (gpu)
        {
            try
            {
                var options = new SessionOptions { EnableMemoryPattern = false, ExecutionMode = ExecutionMode.ORT_SEQUENTIAL };
                options.AppendExecutionProvider_DML(0);
                return (new InferenceSession(model, options), true);
            }
            catch (Exception e) when (e is OnnxRuntimeException or EntryPointNotFoundException or DllNotFoundException)
            {
                // No DirectX 12 card or driver: the processor.
            }
        }
        var cpu = new SessionOptions { IntraOpNumThreads = Math.Max(1, Environment.ProcessorCount / 2) };
        return (new InferenceSession(model, cpu), false);
    }

    /// <summary>A Vision Transformer of a Hugging Face repo as an ONNX model, built once next to the app's other data.</summary>
    public static string BuiltVit(string folder, string name)
    {
        string directory = Path.Combine(AppData.Directory, "models");
        Directory.CreateDirectory(directory);
        var weights = new FileInfo(Path.Combine(folder, "model.safetensors"));
        string path = Path.Combine(directory, $"{name}-v{VitOnnx.BuildVersion}-{weights.Length}-{weights.LastWriteTimeUtc.Ticks}.onnx");
        if (!File.Exists(path))
        {
            File.WriteAllBytes(path + ".tmp", VitOnnx.Build(folder));
            File.Move(path + ".tmp", path, overwrite: true);
        }
        return path;
    }
}
