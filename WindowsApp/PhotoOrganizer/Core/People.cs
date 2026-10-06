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
    const float JoinSimilarity = 0.45f;    // a face joins a group at least this similar (cosine) to its average face
    const float MergeSimilarity = 0.55f;   // a group joins a person whose average face (all joined so far) is at least this similar
    // Faces of one person are on average at least this similar to each other; a group below it is a mix of faces
    // that cannot be told apart (turned away, blurred, babies, animals) and is not listed as a person.
    const double MinimumCoherence = 0.38;
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

    /// <summary>
    /// Blocking. People with too few photos to be worth listing are left out; named people first, then by files.
    /// `previous`: the groups made before from the same files, whose numbers the same people keep.
    /// </summary>
    public static List<Person> PeopleIn(IEnumerable<PhotoItem> items, IReadOnlyList<Person>? previous = null)
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

        // Pass 2: groups with nearly the same average face are one person seen in different conditions. Largest first,
        // each group joins the person whose average face — of everything joined so far — is similar enough. Not a chain
        // of pairs (A like B, B like C…): that joined nearly everybody into one person once most faces were found.
        var groupSizes = new int[sums.Count];
        foreach (int g in assignment) groupSizes[g]++;
        var personSums = new List<float[]>();
        var personCentroids = new List<float[]>();
        var personOf = new int[sums.Count];
        foreach (int g in Enumerable.Range(0, sums.Count).OrderByDescending(g => groupSizes[g]))
        {
            int best = -1;
            float bestScore = MergeSimilarity;
            for (int p = 0; p < personCentroids.Count; p++)
            {
                float score = Dot(personCentroids[p], centroids[g]);
                if (score >= bestScore) { bestScore = score; best = p; }
            }
            if (best < 0)
            {
                best = personSums.Count;
                personSums.Add((float[])sums[g].Clone());
                personCentroids.Add((float[])centroids[g].Clone());
            }
            else
            {
                TensorPrimitives.Add(personSums[best], sums[g], personSums[best]);
                personSums[best].CopyTo(personCentroids[best], 0);
                Normalize(personCentroids[best]);
            }
            personOf[g] = best;
        }
        var members = Enumerable.Range(0, faces.Count).GroupBy(f => personOf[assignment[f]]).Select(g => g.ToList()).ToList();

        var names = LoadNames();
        var namedPeople = new Dictionary<string, Person>();
        var people = new List<Person>();
        foreach (var list in members)
        {
            var centroid = new float[Dimension];
            foreach (int f in list) TensorPrimitives.Add(centroid, faces[f], centroid);
            // The mean similarity of every two faces of the group, from the length of their sum (the faces are unit length).
            double n = list.Count, squared = TensorPrimitives.SumOfSquares(centroid);
            double coherence = n > 1 ? (squared - n) / (n * (n - 1)) : 1;
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
            if (name == null && (files.Count < MinimumFilesPerPerson || coherence < MinimumCoherence)) continue;

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
        // While the analysis runs the groups are made again every few seconds and grow: a group that is still the same
        // person keeps the number it had, so the person shown does not turn into someone else.
        var kept = new Dictionary<Person, int>();
        var earlier = (previous ?? []).Where(p => !p.Named && p.Centroid != null && p.Key.StartsWith('#')).ToList();
        var pairs = new List<(float Score, Person New, Person Old)>();
        foreach (var person in people.Where(p => !p.Named))
        {
            foreach (var old in earlier)
            {
                float score = Dot(person.Centroid!, old.Centroid!);
                if (score >= MergeSimilarity) pairs.Add((score, person, old));
            }
        }
        var taken = new HashSet<Person>();
        foreach (var (_, person, old) in pairs.OrderByDescending(p => p.Score))
        {
            if (kept.ContainsKey(person) || !taken.Add(old)) continue;
            kept[person] = int.Parse(old.Key.AsSpan(1));
        }
        // Everyone else gets the smallest number not taken, so the numbers stay 1, 2, 3… (handing out ever new ones ran
        // them up to hundreds while the groups were made again and again).
        var usedNumbers = kept.Values.ToHashSet();
        int number = 0;
        foreach (var person in people)
        {
            if (person.Named) person.Key = person.DisplayName;
            else
            {
                if (!kept.TryGetValue(person, out int own))
                {
                    do number++; while (usedNumbers.Contains(number));
                    own = number;
                }
                person.Key = $"#{own}";
                person.DisplayName = F("Человек %lu", own);
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
