using System.Numerics.Tensors;
using System.Text.Json;
using System.Text.Json.Nodes;
using static PhotoOrganizer.Core.Strings;

namespace PhotoOrganizer.Core;

/// <summary>A group of faces that look like one person, and the files they appear in.</summary>
public sealed class Person
{
    /// <summary>Stable while the app runs: the name for named people, "#n" otherwise.</summary>
    public string Key { get; internal set; } = "";
    /// <summary>"Человек 3" until the user names the group.</summary>
    public string DisplayName { get; internal set; } = "";
    public bool Named { get; internal set; }
    public List<PhotoItem> Items { get; internal set; } = [];
    /// <summary>The files in which this person is the only one: every face found in them is theirs.</summary>
    public List<PhotoItem> SoloItems { get; internal set; } = [];
    public int FaceCount { get; internal set; }
    public float[]? Centroid { get; internal set; }
    /// <summary>The face that shows this person most typically, preferably where they are alone: (file, face index).</summary>
    public (PhotoItem Item, int Face)? Representative { get; internal set; }
    internal Dictionary<PhotoItem, int> FacesPerFile = [];
}

/// <summary>
/// Groups the faces found by the analyzer into people. Names given by the user are remembered together with what the
/// face looks like, so the same person is recognised again in another folder or after a rescan.
/// </summary>
public static class People
{
    const float JoinSimilarity = 0.42f;    // a face joins a group at least this similar (cosine) to its average face
    const float MergeSimilarity = 0.50f;   // two groups are one person when their average faces are at least this similar
    const float NameSimilarity = 0.45f;    // a stored name applies to a group at least this similar to the named one
    public const float SearchSimilarity = 0.42f;   // search by face: a photo matches when one of its faces is this similar
    const int MinimumFilesPerPerson = 4;
    public const int Dimension = 512;

    static string NamesPath => AppData.File("people.json");

    static List<(string Name, float[] Face)> LoadNames()
    {
        var names = new List<(string, float[])>();
        try
        {
            if (JsonNode.Parse(File.ReadAllText(NamesPath)) is not JsonArray array) return names;
            foreach (var entry in array)
            {
                if (entry?["name"]?.GetValue<string>() is not { } name || entry["face"] is not JsonArray face || face.Count != Dimension) continue;
                names.Add((name, face.Select(v => v!.GetValue<float>()).ToArray()));
            }
        }
        catch (Exception e) when (e is IOException or JsonException or InvalidOperationException or UnauthorizedAccessException)
        {
        }
        return names;
    }

    /// <summary>The int8 embedding as a unit-length float vector.</summary>
    public static float[] Vector(byte[] embedding)
    {
        var vector = new float[Dimension];
        for (int i = 0; i < Dimension; i++) vector[i] = (sbyte)embedding[i];
        Normalize(vector);
        return vector;
    }

    static void Normalize(Span<float> vector)
    {
        float norm = TensorPrimitives.Norm(vector);
        if (norm > 0) TensorPrimitives.Divide(vector, norm, vector);
    }

    static float Dot(ReadOnlySpan<float> a, ReadOnlySpan<float> b) => TensorPrimitives.Dot(a, b);

    /// <summary>Blocking. People with too few photos to be worth listing are left out; named people first, then by files.</summary>
    public static List<Person> PeopleIn(IEnumerable<PhotoItem> items)
    {
        var owners = new List<PhotoItem>();
        var faceIndexes = new List<int>();
        var faces = new List<float[]>();
        foreach (var item in items)
        {
            if (item.Faces == null) continue;
            for (int f = 0; f < item.Faces.Count; f++)
            {
                if (item.Faces[f].Length != Dimension) continue;
                owners.Add(item);
                faceIndexes.Add(f);
                faces.Add(Vector(item.Faces[f]));
            }
        }
        if (faces.Count == 0) return [];

        // Pass 1: each face joins the most similar existing group or starts a new one. Groups are represented by the
        // sum of their faces; `centroids` holds the same sums scaled to unit length for comparing.
        var sums = new List<float[]>();
        var centroids = new List<float[]>();
        var assignment = new int[faces.Count];
        for (int face = 0; face < faces.Count; face++)
        {
            int best = -1;
            float bestScore = JoinSimilarity;
            for (int g = 0; g < centroids.Count; g++)
            {
                float score = Dot(centroids[g], faces[face]);
                if (score >= bestScore) { bestScore = score; best = g; }
            }
            if (best < 0)
            {
                best = sums.Count;
                sums.Add((float[])faces[face].Clone());
                centroids.Add((float[])faces[face].Clone());
            }
            else
            {
                TensorPrimitives.Add(sums[best], faces[face], sums[best]);
                sums[best].CopyTo(centroids[best], 0);
                Normalize(centroids[best]);
            }
            assignment[face] = best;
        }

        // Pass 2: groups that ended up with nearly the same average face are one person seen in different conditions.
        var parent = Enumerable.Range(0, centroids.Count).ToArray();
        int Find(int i)
        {
            while (parent[i] != i) { parent[i] = parent[parent[i]]; i = parent[i]; }
            return i;
        }
        for (int i = 0; i < centroids.Count; i++)
        {
            for (int j = i + 1; j < centroids.Count; j++)
            {
                if (Dot(centroids[i], centroids[j]) >= MergeSimilarity) parent[Find(j)] = Find(i);
            }
        }
        var members = Enumerable.Range(0, faces.Count).GroupBy(f => Find(assignment[f])).Select(g => g.ToList()).ToList();

        var names = LoadNames();
        var namedPeople = new Dictionary<string, Person>();
        var people = new List<Person>();
        foreach (var list in members)
        {
            var centroid = new float[Dimension];
            foreach (int f in list) TensorPrimitives.Add(centroid, faces[f], centroid);
            Normalize(centroid);
            var files = new List<PhotoItem>();
            var facesPerFile = new Dictionary<PhotoItem, int>();
            foreach (int f in list)
            {
                if (!facesPerFile.ContainsKey(owners[f])) files.Add(owners[f]);
                facesPerFile[owners[f]] = facesPerFile.GetValueOrDefault(owners[f]) + 1;
            }
            string? name = null;
            float bestName = NameSimilarity;
            foreach (var (stored, face) in names)
            {
                float score = Dot(centroid, face);
                if (score >= bestName) { bestName = score; name = stored; }
            }
            if (name == null && files.Count < MinimumFilesPerPerson) continue;

            // The face nearest to the average one; photos with a single face win.
            int bestFace = list[0];
            float representativeScore = float.MinValue;
            foreach (int f in list)
            {
                float score = Dot(centroid, faces[f]) + (owners[f].Faces!.Count == 1 ? 2 : 0);
                if (score > representativeScore) { representativeScore = score; bestFace = f; }
            }

            if (name != null && namedPeople.TryGetValue(name, out var existing))
            {
                // Two groups carrying the same name: one person.
                foreach (var file in files)
                {
                    if (!existing.FacesPerFile.ContainsKey(file)) existing.Items.Add(file);
                    existing.FacesPerFile[file] = existing.FacesPerFile.GetValueOrDefault(file) + facesPerFile[file];
                }
                existing.FaceCount += list.Count;
                continue;
            }
            var person = new Person
            {
                Named = name != null,
                DisplayName = name ?? "",
                Items = files,
                FaceCount = list.Count,
                FacesPerFile = facesPerFile,
                Centroid = centroid,
                Representative = (owners[bestFace], faceIndexes[bestFace]),
            };
            if (name != null) namedPeople[name] = person;
            people.Add(person);
        }

        people.Sort((a, b) => a.Named != b.Named ? (a.Named ? -1 : 1)
                            : a.Items.Count != b.Items.Count ? b.Items.Count.CompareTo(a.Items.Count)
                            : string.Compare(a.DisplayName, b.DisplayName, StringComparison.CurrentCultureIgnoreCase));
        int number = 0;
        foreach (var person in people)
        {
            if (person.Named) person.Key = person.DisplayName;
            else
            {
                number++;
                person.Key = $"#{number}";
                person.DisplayName = F("Человек %lu", number);
            }
            // Alone: this person's is the only face, and nobody else shows up — not even without a usable face.
            person.SoloItems = person.Items.Where(i => i.Faces!.Count == 1 && person.FacesPerFile.GetValueOrDefault(i) == 1
                                                       && (i.PeopleCount == null || i.PeopleCount <= 1))
                                           .OrderBy(i => i.Date).ToList();
            person.FacesPerFile = [];
            person.Items = person.Items.OrderBy(i => i.Date).ToList();
        }
        return people;
    }

    /// <summary>Names (or renames) a person. An empty name forgets the name.</summary>
    public static void SetName(string? name, Person person)
    {
        name = (name ?? "").Trim();
        var entries = new JsonArray();
        foreach (var (stored, face) in LoadNames())
        {
            if (person.Named && stored == person.DisplayName)
            {
                // Renaming keeps every remembered look of the person; an empty name forgets them.
                if (name.Length > 0) entries.Add(Entry(name, face));
            }
            else
            {
                entries.Add(Entry(stored, face));
            }
        }
        if (name.Length > 0 && !person.Named && person.Centroid != null) entries.Add(Entry(name, person.Centroid));
        AppData.WriteAtomically(NamesPath, entries.ToJsonString());
    }

    static JsonObject Entry(string name, float[] face) =>
        new() { ["name"] = name, ["face"] = new JsonArray(face.Select(v => (JsonNode)MathF.Round(v, 5)).ToArray()) };

    /// <summary>Search by face: the files where someone looks like `embedding`, most alike first, with their scores.</summary>
    public static List<(float Score, PhotoItem Item)> ItemsWithFace(IEnumerable<PhotoItem> items, byte[] embedding)
    {
        var query = Vector(embedding);
        var found = new List<(float, PhotoItem)>();
        foreach (var item in items)
        {
            if (item.Faces is not { Count: > 0 }) continue;
            float best = item.Faces.Max(face => Dot(Vector(face), query));
            if (best >= SearchSimilarity) found.Add((best, item));
        }
        found.Sort((a, b) => b.Item1.CompareTo(a.Item1));
        return found;
    }
}
