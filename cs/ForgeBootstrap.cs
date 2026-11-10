using Godot;

namespace CardRelicForge;

/// <summary>
/// Placeholder so the mono build finds a project assembly to load.
/// CardRelicForge itself is written entirely in GDScript; nothing here is used
/// at runtime beyond satisfying Godot's .NET bootstrap.
/// </summary>
public partial class ForgeBootstrap : Node
{
    public override void _Ready()
    {
        GD.Print("CardRelicForge .NET bootstrap ready.");
    }
}
