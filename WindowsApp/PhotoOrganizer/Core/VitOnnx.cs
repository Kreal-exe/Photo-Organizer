using System.Buffers.Binary;
using System.Text;
using System.Text.Json;

namespace PhotoOrganizer.Core;

/// <summary>Reads the tensors of a .safetensors file as float arrays.</summary>
public static class SafeTensors
{
    public sealed record Tensor(int[] Shape, float[] Data);

    public static Dictionary<string, Tensor> Load(string path)
    {
        byte[] file = File.ReadAllBytes(path);
        long headerLength = BinaryPrimitives.ReadInt64LittleEndian(file);
        using var header = JsonDocument.Parse(file.AsMemory(8, (int)headerLength));
        int dataStart = 8 + (int)headerLength;
        var tensors = new Dictionary<string, Tensor>();
        foreach (var property in header.RootElement.EnumerateObject())
        {
            if (property.Name == "__metadata__") continue;
            string type = property.Value.GetProperty("dtype").GetString()!;
            int[] shape = property.Value.GetProperty("shape").EnumerateArray().Select(e => e.GetInt32()).ToArray();
            var offsets = property.Value.GetProperty("data_offsets").EnumerateArray().Select(e => e.GetInt64()).ToArray();
            var bytes = file.AsSpan(dataStart + (int)offsets[0], (int)(offsets[1] - offsets[0]));
            float[] data = type switch
            {
                "F32" => System.Runtime.InteropServices.MemoryMarshal.Cast<byte, float>(bytes).ToArray(),
                "F16" => System.Runtime.InteropServices.MemoryMarshal.Cast<byte, Half>(bytes).ToArray().Select(h => (float)h).ToArray(),
                "BF16" => System.Runtime.InteropServices.MemoryMarshal.Cast<byte, ushort>(bytes).ToArray()
                              .Select(b => BitConverter.Int32BitsToSingle(b << 16)).ToArray(),
                _ => throw new InvalidDataException($"Unsupported tensor type {type}"),
            };
            tensors[property.Name] = new Tensor(shape, data);
        }
        return tensors;
    }
}

/// <summary>What a Vision Transformer of a Hugging Face repo expects and gives.</summary>
public sealed record VitInfo(int InputSize, float[] Mean, float[] Std, string[] Labels);

/// <summary>
/// Turns a Vision Transformer of a Hugging Face repo — timm's VisionTransformer (the ArcFace face model, Marqo's
/// nudity model) or transformers' ViTForImageClassification (Falconsai's, AdamCodd's) — into an ONNX model, so that
/// ONNX Runtime can run it on the graphics card. These are the weights the macOS version runs with MLX. Written by
/// hand — the format is a few protobuf messages — to keep the app free of a protobuf library.
///
/// The model takes "input": float [N, size, size, 3], RGB already normalised with the model's mean and std, and gives
/// "output": float [N, classes] — the logits of a classifier, or the (not yet unit-length) embedding of ArcFace.
/// </summary>
public static class VitOnnx
{
    public const int Opset = 17;

    /// <summary>The layout of the weights: timm's names, or transformers' with separate query, key and value.</summary>
    sealed record Layout(bool Timm, int Blocks, int Heads, float Epsilon, Func<int, string, string> Block, string Patch, string Cls,
                         string Position, string Norm, string Head);

    static JsonElement? ReadJson(string path)
    {
        if (!File.Exists(path)) return null;
        using var document = JsonDocument.Parse(File.ReadAllText(path));
        return document.RootElement.Clone();
    }

    public static VitInfo Info(string folder)
    {
        var config = ReadJson(Path.Combine(folder, "config.json")) ?? throw new InvalidDataException("config.json is missing");
        static float[] Floats(JsonElement e) => e.EnumerateArray().Select(v => v.GetSingle()).ToArray();
        if (config.TryGetProperty("pretrained_cfg", out var cfg))   // timm
        {
            string[] labels = config.TryGetProperty("label_names", out var names) ? names.EnumerateArray().Select(n => n.GetString() ?? "").ToArray() : [];
            return new VitInfo(cfg.GetProperty("input_size")[2].GetInt32(),
                               cfg.TryGetProperty("mean", out var mean) ? Floats(mean) : [0.5f, 0.5f, 0.5f],
                               cfg.TryGetProperty("std", out var std) ? Floats(std) : [0.5f, 0.5f, 0.5f], labels);
        }
        var preprocessor = ReadJson(Path.Combine(folder, "preprocessor_config.json"));
        var id2label = config.GetProperty("id2label");
        var ordered = Enumerable.Range(0, id2label.EnumerateObject().Count()).Select(i => id2label.GetProperty(i.ToString()).GetString() ?? "").ToArray();
        float[] Normal(string name) => preprocessor is { } p && p.TryGetProperty(name, out var v) ? Floats(v) : [0.5f, 0.5f, 0.5f];
        return new VitInfo(config.GetProperty("image_size").GetInt32(), Normal("image_mean"), Normal("image_std"), ordered);
    }

    static Layout LayoutOf(string folder, Dictionary<string, SafeTensors.Tensor> w)
    {
        if (w.ContainsKey("cls_token"))
        {
            int blocks = 1 + w.Keys.Where(k => k.StartsWith("blocks.")).Max(k => int.Parse(k.Split('.')[1]));
            int dim = w["cls_token"].Shape[^1];
            int heads = dim switch { 192 => 3, 384 => 6, 768 => 12, 1024 => 16, _ => throw new InvalidDataException("Unknown ViT width") };
            return new Layout(true, blocks, heads, 1e-6f, (i, part) => $"blocks.{i}.{part}", "patch_embed.proj", "cls_token", "pos_embed", "norm", "head");
        }
        var config = ReadJson(Path.Combine(folder, "config.json"))!.Value;
        float epsilon = config.TryGetProperty("layer_norm_eps", out var eps) ? eps.GetSingle() : 1e-12f;
        return new Layout(false, config.GetProperty("num_hidden_layers").GetInt32(), config.GetProperty("num_attention_heads").GetInt32(), epsilon,
                          (i, part) => $"vit.encoder.layer.{i}.{part}", "vit.embeddings.patch_embeddings.projection", "vit.embeddings.cls_token",
                          "vit.embeddings.position_embeddings", "vit.layernorm", "classifier");
    }

    /// <summary>The model in the folder (config.json, model.safetensors, maybe preprocessor_config.json) as ONNX.</summary>
    public static byte[] Build(string folder)
    {
        var w = SafeTensors.Load(Path.Combine(folder, "model.safetensors"));
        var layout = LayoutOf(folder, w);
        var cls = w[layout.Cls];
        int dim = cls.Shape[^1];
        var patchWeight = w[layout.Patch + ".weight"];   // [dim, 3, p, p]
        int patch = patchWeight.Shape[2];
        var pos = w[layout.Position];                     // [1, tokens, dim]
        int tokens = pos.Shape[1];
        int grid = (int)Math.Round(Math.Sqrt(tokens - 1));
        int heads = layout.Heads, headDim = dim / heads;

        var g = new GraphBuilder();
        // The patch convolution has stride == kernel: a matrix product over flattened patches (channels last).
        var patchMatrix = new float[patch * patch * 3 * dim];
        for (int o = 0; o < dim; o++)
            for (int c = 0; c < 3; c++)
                for (int py = 0; py < patch; py++)
                    for (int px = 0; px < patch; px++)
                        patchMatrix[((py * patch + px) * 3 + c) * dim + o] = patchWeight.Data[((o * 3 + c) * patch + py) * patch + px];

        string x0 = g.Node("Reshape", ["input", g.Int64s("shape_patches", [-1, grid, patch, grid, patch, 3])]);
        string x1 = g.Node("Transpose", [x0], ints: ("perm", [0, 1, 3, 2, 4, 5]));
        string x2 = g.Node("Reshape", [x1, g.Int64s("shape_tokens", [-1, grid * grid, patch * patch * 3])]);
        string embedded = Linear(g, x2, patchMatrix, patch * patch * 3, dim, w[layout.Patch + ".bias"].Data, "patch");
        // The class token, repeated for every picture of the batch: the first patch times zero, plus the token.
        string first = g.Node("Slice", [embedded, g.Int64s("zero1", [0]), g.Int64s("one1", [1]), g.Int64s("axis1", [1])]);
        string zeroed = g.Node("Mul", [first, g.Float("zero", [], [0f])]);
        string clsTokens = g.Node("Add", [zeroed, g.Float("cls", [1, 1, dim], cls.Data)]);
        string x = g.Node("Concat", [clsTokens, embedded], ints: null, intAttribute: ("axis", 1));
        x = g.Node("Add", [x, g.Float("pos", [1, tokens, dim], pos.Data)]);

        string scale = g.Float("attention_scale", [], [MathF.Pow(headDim, -0.5f)]);
        string invSqrt2 = g.Float("inv_sqrt2", [], [1 / MathF.Sqrt(2)]);
        string one = g.Float("one", [], [1f]);
        string half = g.Float("half", [], [0.5f]);
        string qkvShape = g.Int64s("shape_qkv", [-1, tokens, 3, heads, headDim]);
        string mergeShape = g.Int64s("shape_merge", [-1, tokens, dim]);
        string[] pick = [g.Int64Scalar("index0", 0), g.Int64Scalar("index1", 1), g.Int64Scalar("index2", 2)];
        for (int i = 0; i < layout.Blocks; i++)
        {
            int block = i;
            string B(string part) => layout.Block(block, part);
            float[] qkvWeight, qkvBias;
            string norm1, norm2, proj, fc1, fc2;
            if (layout.Timm)
            {
                (qkvWeight, qkvBias) = (Transposed(w[B("attn.qkv.weight")]), w[B("attn.qkv.bias")].Data);
                (norm1, norm2, proj, fc1, fc2) = ("norm1", "norm2", "attn.proj", "mlp.fc1", "mlp.fc2");
            }
            else
            {
                // Query, key and value are three matrices here; stacked they are timm's one.
                string[] names = ["query", "key", "value"];
                var joined = new SafeTensors.Tensor([3 * dim, dim], names.SelectMany(n => w[B($"attention.attention.{n}.weight")].Data).ToArray());
                qkvWeight = Transposed(joined);
                qkvBias = names.SelectMany(n => w[B($"attention.attention.{n}.bias")].Data).ToArray();
                (norm1, norm2, proj, fc1, fc2) = ("layernorm_before", "layernorm_after", "attention.output.dense", "intermediate.dense", "output.dense");
            }
            string h = LayerNorm(g, x, w[B(norm1 + ".weight")].Data, w[B(norm1 + ".bias")].Data, $"b{i}n1", layout.Epsilon);
            string qkv = Linear(g, h, qkvWeight, dim, 3 * dim, qkvBias, $"b{i}qkv");
            string split = g.Node("Transpose", [g.Node("Reshape", [qkv, qkvShape])], ints: ("perm", [2, 0, 3, 1, 4]));
            string q = g.Node("Gather", [split, pick[0]], intAttribute: ("axis", 0));
            string k = g.Node("Gather", [split, pick[1]], intAttribute: ("axis", 0));
            string v = g.Node("Gather", [split, pick[2]], intAttribute: ("axis", 0));
            string scores = g.Node("Mul", [g.Node("MatMul", [q, g.Node("Transpose", [k], ints: ("perm", [0, 1, 3, 2]))]), scale]);
            string attention = g.Node("Softmax", [scores], intAttribute: ("axis", -1));
            string mixed = g.Node("Reshape", [g.Node("Transpose", [g.Node("MatMul", [attention, v])], ints: ("perm", [0, 2, 1, 3])), mergeShape]);
            x = g.Node("Add", [x, Linear(g, mixed, Transposed(w[B(proj + ".weight")]), dim, dim, w[B(proj + ".bias")].Data, $"b{i}proj")]);
            h = LayerNorm(g, x, w[B(norm2 + ".weight")].Data, w[B(norm2 + ".bias")].Data, $"b{i}n2", layout.Epsilon);
            int hidden = w[B(fc1 + ".weight")].Shape[0];
            string f = Linear(g, h, Transposed(w[B(fc1 + ".weight")]), dim, hidden, w[B(fc1 + ".bias")].Data, $"b{i}fc1");
            // GELU, exact: x · (1 + erf(x / √2)) / 2.
            string gelu = g.Node("Mul", [g.Node("Mul", [f, g.Node("Add", [g.Node("Erf", [g.Node("Mul", [f, invSqrt2])]), one])]), half]);
            x = g.Node("Add", [x, Linear(g, gelu, Transposed(w[B(fc2 + ".weight")]), hidden, dim, w[B(fc2 + ".bias")].Data, $"b{i}fc2")]);
        }
        x = LayerNorm(g, x, w[layout.Norm + ".weight"].Data, w[layout.Norm + ".bias"].Data, "norm", layout.Epsilon);
        string token = g.Node("Gather", [x, pick[0]], intAttribute: ("axis", 1));
        var head = w[layout.Head + ".weight"];
        string output = Linear(g, token, Transposed(head), dim, head.Shape[0], w[layout.Head + ".bias"].Data, "head", output: "output");
        int size = grid * patch;
        return g.Model("vit", ("input", ["N", size, size, 3]), ("output", ["N", head.Shape[0]]), output);
    }

    /// <summary>[out, in] → [in, out], for x · W.</summary>
    static float[] Transposed(SafeTensors.Tensor tensor)
    {
        int rows = tensor.Shape[0], columns = tensor.Shape[1];
        var result = new float[rows * columns];
        for (int r = 0; r < rows; r++)
            for (int c = 0; c < columns; c++)
                result[c * rows + r] = tensor.Data[r * columns + c];
        return result;
    }

    static string Linear(GraphBuilder g, string x, float[] weight, int inputs, int outputs, float[] bias, string name, string? output = null)
    {
        string product = g.Node("MatMul", [x, g.Float(name + ".w", [inputs, outputs], weight)]);
        return g.Node("Add", [product, g.Float(name + ".b", [outputs], bias)], output: output);
    }

    static string LayerNorm(GraphBuilder g, string x, float[] scale, float[] bias, string name, float epsilon) =>
        g.Node("LayerNormalization", [x, g.Float(name + ".scale", [scale.Length], scale), g.Float(name + ".bias", [bias.Length], bias)],
               intAttribute: ("axis", -1), floatAttribute: ("epsilon", epsilon));

    /// <summary>The few parts of ONNX's protobuf schema this model needs.</summary>
    sealed class GraphBuilder
    {
        readonly List<byte[]> _nodes = [];
        readonly List<byte[]> _initializers = [];
        int _counter;

        public string Float(string name, int[] dims, float[] data)
        {
            var bytes = new byte[data.Length * 4];
            Buffer.BlockCopy(data, 0, bytes, 0, bytes.Length);
            _initializers.Add(Tensor(name, dims.Select(d => (long)d).ToArray(), 1, bytes));
            return name;
        }

        public string Int64s(string name, long[] values)
        {
            var bytes = new byte[values.Length * 8];
            Buffer.BlockCopy(values, 0, bytes, 0, bytes.Length);
            _initializers.Add(Tensor(name, [values.Length], 7, bytes));
            return name;
        }

        public string Int64Scalar(string name, long value)
        {
            _initializers.Add(Tensor(name, [], 7, BitConverter.GetBytes(value)));
            return name;
        }

        static byte[] Tensor(string name, long[] dims, int type, byte[] raw)
        {
            var p = new Proto();
            foreach (long d in dims) p.Varint(1, d);
            p.Varint(2, type);
            p.String(8, name);
            p.Bytes(9, raw);
            return p.ToArray();
        }

        public string Node(string op, string[] inputs, (string Name, long[] Values)? ints = null, (string Name, long Value)? intAttribute = null,
                           (string Name, float Value)? floatAttribute = null, string? output = null)
        {
            output ??= $"{op}_{_counter++}";
            var p = new Proto();
            foreach (string input in inputs) p.String(1, input);
            p.String(2, output);
            p.String(3, $"node_{_counter++}");
            p.String(4, op);
            if (ints is { } list)
            {
                var a = new Proto();
                a.String(1, list.Name);
                foreach (long v in list.Values) a.Varint(8, v);
                a.Varint(20, 7);   // INTS
                p.Message(5, a);
            }
            if (intAttribute is { } single)
            {
                var a = new Proto();
                a.String(1, single.Name);
                a.Varint(3, single.Value);
                a.Varint(20, 2);   // INT
                p.Message(5, a);
            }
            if (floatAttribute is { } f)
            {
                var a = new Proto();
                a.String(1, f.Name);
                a.Fixed32(2, BitConverter.SingleToInt32Bits(f.Value));
                a.Varint(20, 1);   // FLOAT
                p.Message(5, a);
            }
            _nodes.Add(p.ToArray());
            return output;
        }

        static Proto ValueInfo(string name, object[] dims)
        {
            var shape = new Proto();
            foreach (object d in dims)
            {
                var dimension = new Proto();
                if (d is string symbol) dimension.String(2, symbol); else dimension.Varint(1, Convert.ToInt64(d));
                shape.Message(1, dimension);
            }
            var tensor = new Proto();
            tensor.Varint(1, 1);   // FLOAT
            tensor.Message(2, shape);
            var type = new Proto();
            type.Message(1, tensor);
            var info = new Proto();
            info.String(1, name);
            info.Message(2, type);
            return info;
        }

        public byte[] Model(string name, (string Name, object[] Dims) input, (string Name, object[] Dims) output, string producedOutput)
        {
            if (producedOutput != output.Name) throw new InvalidOperationException("The last node must write the output");
            var graph = new Proto();
            foreach (var node in _nodes) graph.Bytes(1, node);
            graph.String(2, name);
            foreach (var initializer in _initializers) graph.Bytes(5, initializer);
            graph.Message(11, ValueInfo(input.Name, input.Dims));
            graph.Message(12, ValueInfo(output.Name, output.Dims));
            var opset = new Proto();
            opset.String(1, "");
            opset.Varint(2, Opset);
            var model = new Proto();
            model.Varint(1, 8);   // IR version
            model.String(2, "Photo Organizer");
            model.Message(7, graph);
            model.Message(8, opset);
            return model.ToArray();
        }
    }

    /// <summary>Protobuf wire format: varints, fixed32 and length-delimited fields.</summary>
    sealed class Proto
    {
        readonly MemoryStream _stream = new();

        void RawVarint(ulong value)
        {
            while (value >= 0x80)
            {
                _stream.WriteByte((byte)(value | 0x80));
                value >>= 7;
            }
            _stream.WriteByte((byte)value);
        }

        void Tag(int field, int wireType) => RawVarint((ulong)((field << 3) | wireType));

        public void Varint(int field, long value)
        {
            Tag(field, 0);
            RawVarint((ulong)value);
        }

        public void Fixed32(int field, int value)
        {
            Tag(field, 5);
            Span<byte> bytes = stackalloc byte[4];
            BinaryPrimitives.WriteInt32LittleEndian(bytes, value);
            _stream.Write(bytes);
        }

        public void Bytes(int field, byte[] bytes)
        {
            Tag(field, 2);
            RawVarint((ulong)bytes.Length);
            _stream.Write(bytes);
        }

        public void String(int field, string text) => Bytes(field, Encoding.UTF8.GetBytes(text));

        public void Message(int field, Proto message) => Bytes(field, message.ToArray());

        public byte[] ToArray() => _stream.ToArray();
    }
}
