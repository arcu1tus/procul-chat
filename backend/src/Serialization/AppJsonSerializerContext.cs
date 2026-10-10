using System.Text.Json.Serialization;

namespace Procul.Infrastructure.Serialization;

record Dummy(int age);

// TODO swap with actual things
[JsonSerializable(typeof(Dummy))]
internal partial class AppJsonSerializerContext : JsonSerializerContext { }