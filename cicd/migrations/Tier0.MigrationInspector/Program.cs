using System.Reflection;
using System.Runtime.Loader;
using System.Text.Json;
using Microsoft.EntityFrameworkCore.Migrations;
using Microsoft.EntityFrameworkCore.Migrations.Operations;

if (args.Length != 4 || args[0] != "--assembly" || args[2] != "--output")
{
    Console.Error.WriteLine("usage: Tier0.MigrationInspector --assembly PRODUCT.dll --output evidence.json");
    return 64;
}

string assemblyPath = Path.GetFullPath(args[1]);
string outputPath = Path.GetFullPath(args[3]);
if (!File.Exists(assemblyPath))
{
    Console.Error.WriteLine($"migration assembly not found: {assemblyPath}");
    return 66;
}

string assemblyDirectory = Path.GetDirectoryName(assemblyPath)!;
AssemblyLoadContext.Default.Resolving += (_, name) =>
{
    string candidate = Path.Combine(assemblyDirectory, $"{name.Name}.dll");
    return File.Exists(candidate) ? AssemblyLoadContext.Default.LoadFromAssemblyPath(candidate) : null;
};

Assembly assembly = AssemblyLoadContext.Default.LoadFromAssemblyPath(assemblyPath);
var migrations = new List<object>();
foreach (Type type in assembly.GetTypes().Where(t => !t.IsAbstract && typeof(Migration).IsAssignableFrom(t)))
{
    string migrationId = type.GetCustomAttribute<MigrationAttribute>()?.Id
        ?? throw new InvalidOperationException($"Migration type has no MigrationAttribute: {type.FullName}");
    var migration = (Migration)(Activator.CreateInstance(type, nonPublic: true)
        ?? throw new InvalidOperationException($"Cannot create migration: {type.FullName}"));
    typeof(Migration).GetProperty(nameof(Migration.ActiveProvider))!
        .SetValue(migration, "Npgsql.EntityFrameworkCore.PostgreSQL");

    var operations = migration.UpOperations.Select(operation => Describe(operation)).ToArray();
    string classification = operations.All(operation => operation.Additive) ? "pure-additive" : "data-sensitive";
    migrations.Add(new
    {
        migration = migrationId,
        type = type.FullName,
        classification,
        operations = operations.Select(operation => new
        {
            operation.Type,
            operation.Table,
            operation.Column,
            operation.Additive,
            operation.Reason,
        }),
    });
}

if (migrations.Count == 0)
{
    Console.Error.WriteLine("no EF Migration types found; refusing an empty classification");
    return 1;
}

Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);
string temporary = $"{outputPath}.{Environment.ProcessId}.tmp";
File.WriteAllText(temporary, JsonSerializer.Serialize(new
{
    schema = 1,
    classifierVersion = "tier0-structured-v1",
    provider = "Npgsql.EntityFrameworkCore.PostgreSQL",
    migrations,
}, new JsonSerializerOptions
{
    WriteIndented = true,
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
}));
File.Move(temporary, outputPath, overwrite: true);
return 0;

static OperationEvidence Describe(MigrationOperation operation)
{
    return operation switch
    {
        CreateTableOperation create => new(operation.GetType().Name, create.Name, null, true,
            "strict allowlist: create new table"),
        AddColumnOperation add when add.IsNullable && add.DefaultValue is null
            && add.DefaultValueSql is null && add.ComputedColumnSql is null
            => new(operation.GetType().Name, add.Table, add.Name, true,
                "strict allowlist: add nullable column without default or computed SQL"),
        AddColumnOperation add => new(operation.GetType().Name, add.Table, add.Name, false,
            "column is non-nullable or has a default/computed expression"),
        SqlOperation => new(operation.GetType().Name, null, null, false, "raw SQL is always risky"),
        _ => new(operation.GetType().Name, Table(operation), Column(operation), false,
            "operation is not on the strict additive allowlist"),
    };
}

static string? StringProperty(MigrationOperation operation, string name)
    => operation.GetType().GetProperty(name)?.GetValue(operation) as string;

static string? Table(MigrationOperation operation)
    => StringProperty(operation, "Table") ?? StringProperty(operation, "Name");

static string? Column(MigrationOperation operation)
    => StringProperty(operation, "Column") ?? StringProperty(operation, "NewName");

internal sealed record OperationEvidence(
    string Type,
    string? Table,
    string? Column,
    bool Additive,
    string Reason);
