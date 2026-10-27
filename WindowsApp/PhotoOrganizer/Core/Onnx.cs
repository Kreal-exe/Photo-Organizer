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

    /// <summary>
    /// Several sessions of one model, as many as the graphics card is given (see OnnxPool); on the processor one, which
    /// spreads each call over its cores already.
    /// </summary>
    public static OnnxPool Pool(byte[] model, bool gpu) => new(model, gpu);

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

/// <summary>
/// Sessions of one model taken in turn: a DirectML session runs one call at a time, so with one the pictures of the
/// workers waited in line and the graphics card was mostly idle; with several they run on it side by side.
/// </summary>
public sealed class OnnxPool : IDisposable
{
    /// <summary>Sessions per model on the graphics card: enough to keep it busy, few enough for its memory.</summary>
    public const int GpuSessions = 4;

    readonly List<InferenceSession> _all = [];
    readonly System.Collections.Concurrent.BlockingCollection<InferenceSession> _free = [];

    public bool Gpu { get; }

    public OnnxPool(byte[] model, bool gpu)
    {
        var (first, onGpu) = Onnx.Open(model, gpu);
        Gpu = onGpu;
        Add(first);
        for (int i = 1; onGpu && i < GpuSessions; i++)
        {
            try
            {
                var (session, again) = Onnx.Open(model, true);
                if (!again)
                {
                    session.Dispose();
                    break;
                }
                Add(session);
            }
            catch (OnnxRuntimeException)
            {
                break;   // out of graphics memory: the sessions made so far
            }
        }
    }

    void Add(InferenceSession session)
    {
        _all.Add(session);
        _free.Add(session);
    }

    /// <summary>Runs `work` on a free session, waiting for one when all are busy.</summary>
    public T Run<T>(Func<InferenceSession, T> work)
    {
        var session = _free.Take();
        try
        {
            return work(session);
        }
        finally
        {
            _free.Add(session);
        }
    }

    public void Dispose()
    {
        foreach (var session in _all) session.Dispose();
        _free.Dispose();
    }
}
