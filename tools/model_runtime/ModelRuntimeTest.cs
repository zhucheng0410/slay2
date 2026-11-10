using System;
using System.Reflection;
using System.Runtime.Loader;
using System.Runtime.CompilerServices;
using Godot;
using ForgeModelProbe.Models.Characters;
using MegaCrit.Sts2.Core.Models;
using MegaCrit.Sts2.Core.Nodes.Combat;
using MegaCrit.Sts2.Core.Nodes.Vfx;
using MegaCrit.Sts2.Core.Entities.Players;
using MegaCrit.Sts2.addons.mega_text;
using STS2RitsuLib.Scaffolding.Godot;
using STS2RitsuLib.Scaffolding.Visuals.StateMachine;

// An isolated Godot host for the real game/RitsuLib classes. No game saves or
// installation files are opened, and no rendering window is needed.
public partial class ModelRuntimeTest : Node
{
    private int _checks;
    private void Check(string label, bool passed)
    {
        _checks++;
        if (!passed) throw new InvalidOperationException(label);
        GD.Print("[OK] " + label);
    }

    private void CheckIndependentCharacter(CharacterModel character)
    {
        var type = character.GetType();
        string Path(string name) => (string)type.GetProperty(name)!.GetValue(character)!;
        Check($"{type.Name}: no vanilla placeholder", type.GetProperty("PlaceholderCharacterId")!.GetValue(character) == null);
        Check($"{type.Name}: zero initial orb slots", character.BaseOrbSlotCount == 0);
        Check($"{type.Name}: no default star counter", !character.ShouldAlwaysShowStarCounter);
        // A minimal player fixture avoids SaveManager initialization. Copy the
        // character's base capacity just as Player.CreateForNewRun does, then
        // execute the real combat-state constructor (including OrbQueue setup).
        var combatPlayer = (Player)RuntimeHelpers.GetUninitializedObject(typeof(Player));
        combatPlayer.BaseOrbSlotCount = character.BaseOrbSlotCount;
        for (int battle = 1; battle <= 2; battle++)
        {
            var combat = new PlayerCombatState(combatPlayer);
            Check($"{type.Name}: battle {battle} initializes with no orb slots, stars or pets", combat.OrbQueue.Capacity == 0 && combat.Stars == 0 && combat.Pets.Count == 0);
            combat.AfterCombatEnd();
        }
        var poolType = type.BaseType!.GetGenericArguments()[2];
        Check($"{type.Name}: potion pool belongs to own mod", poolType.Assembly == type.Assembly);
        var potionPool = (PotionPoolModel)Activator.CreateInstance(poolType)!;
        Check($"{type.Name}: no inherited character-specific potions", !System.Linq.Enumerable.Any(potionPool.AllPotions));
        var energy = RitsuGodotNodeFactories.CreateFromScenePath<NEnergyCounter>(Path("CustomEnergyCounterPath"));
        Check($"{type.Name}: own energy UI converts to actual game type", energy != null && energy.GetNodeOrNull<MegaLabel>("Label") != null && energy.GetNodeOrNull<Control>("%Layers") != null);
        Check($"{type.Name}: energy VFX and star anchor slots available", energy!.GetNodeOrNull("%EnergyVfxBack") != null && energy.GetNodeOrNull("%EnergyVfxFront") != null && energy.GetNodeOrNull("%StarAnchor") != null);
        energy!.Free();
        var trail = RitsuGodotNodeFactories.CreateFromScenePath<NCardTrailVfx>(Path("CustomTrailPath"));
        Check($"{type.Name}: own card trail converts to actual game type", trail != null && trail.GetNodeOrNull<Node2D>("Sprites") != null);
        trail!.Free();
        Check($"{type.Name}: own transition material loads", ResourceLoader.Load<ShaderMaterial>(Path("CustomCharacterSelectTransitionPath")) != null);
    }

    public override async void _Ready()
    {
        try
        {
            var pack = ProjectSettings.GlobalizePath("res://../../exports/_modeltest/ForgeModelProbe/ForgeModelProbe.pck");
            Check("Fresh process mounts exported PCK", ProjectSettings.LoadResourcePack(pack));
            // The game calls this during RitsuLib startup; reproduce just that
            // registration in this isolated host, without starting a game run.
            var bootstrap = typeof(ModAnimStateMachine).Assembly.GetType("STS2RitsuLib.Scaffolding.Godot.RitsuGodotNodeFactoryBootstrap")!;
            bootstrap.GetMethod("EnsureRegistered", BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic)!.Invoke(null, null);
            var character = new Puppet();
            CheckIndependentCharacter(character);
            Check("Character is unlocked and visible in selection", !character.RequiresEpochAndTimeline && !character.HideFromVanillaCharacterSelect);
            var visuals = (NCreatureVisuals)typeof(Puppet).GetMethod("TryCreateCreatureVisuals", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(character, null)!;
            Check("RitsuLib creates the actual game NCreatureVisuals", visuals != null);
            AddChild(visuals);
            await ToSignal(GetTree(), SceneTree.SignalName.ProcessFrame);
            Check("Game Ready resolves required slots", visuals!.Bounds != null && visuals.VfxSpawnPosition != null && visuals.IntentPosition != null);
            Check("Custom body is not a vanilla Spine model", !visuals.HasSpineAnimation && visuals.GetCurrentBody().GetNode<Sprite2D>("Body").Texture.GetWidth() == 240);
            var machine = (ModAnimStateMachine)typeof(Puppet).GetMethod("SetupCustomCombatAnimationStateMachine", BindingFlags.Instance | BindingFlags.NonPublic)!.Invoke(character, new object[] { visuals, character })!;
            var player = visuals.GetNode<AnimationPlayer>("AnimationPlayer");
            Check("RitsuLib starts idle animation", player.CurrentAnimation == "idle");
            machine.SetTrigger("Attack");
            player.Seek(0.2, true);
            Check("Game Attack trigger moves custom body", player.CurrentAnimation == "attack" && visuals.GetCurrentBody().Position.X > 30);
            player.Advance(0.6);
            await ToSignal(GetTree(), SceneTree.SignalName.ProcessFrame);
            player.Advance(0.01);
            Check("Attack completes back to idle", player.CurrentAnimation == "idle" && Math.Abs(visuals.GetCurrentBody().Position.X) < 0.1);
            machine.SetTrigger("Hit");
            player.Seek(0.15, true);
            Check("Game Hit trigger changes the body", visuals.GetCurrentBody().Position.X < -10);
            machine.SetTrigger("Cast");
            player.Seek(0.275, true);
            Check("Game Cast trigger raises the body", visuals.GetCurrentBody().Position.Y < -10);
            machine.SetTrigger("Dead");
            player.Seek(0.7, true);
            Check("Game Dead trigger holds the death pose", machine.Current?.Id == "dead" && player.AssignedAnimation == "dead" && visuals.GetCurrentBody().Rotation < -1);
            machine.SetTrigger("Revive");
            player.Seek(0, true);
            Check("Game Revive trigger restores idle", player.CurrentAnimation == "idle" && visuals.GetCurrentBody().Modulate.A == 1);
            // Exercise the exact typed game getters that previously threw
            // InvalidCastException and aborted selection/map initialization.
            Check("Game CharacterSelectIcon getter succeeds", character.CharacterSelectIcon.GetWidth() == 132);
            Check("Game locked selection icon getter succeeds", character.CharacterSelectLockedIcon.GetWidth() == 132);
            Check("Game MapMarker getter succeeds", character.MapMarker.GetWidth() > 0);
            Check("Selection background loads independently", ResourceLoader.Load<Texture2D>(character.CustomCharacterSelectBgPath).GetWidth() == 1920);
            foreach (var scenePath in new[] { character.CustomMerchantAnimPath, character.CustomRestSiteAnimPath })
            {
                var world = ResourceLoader.Load<PackedScene>(scenePath).Instantiate<Node2D>();
                AddChild(world);
                Check("World model instantiates", world.GetNode<Sprite2D>("Visuals/Body").Texture != null);
                if (scenePath == character.CustomRestSiteAnimPath)
                    Check("Rest site interaction slots exist", world.GetNodeOrNull<Control>("ControlRoot") != null && world.GetNodeOrNull<Control>("%Hitbox") != null);
                world.QueueFree();
            }
            machine.Dispose();
            visuals.QueueFree();
            // Also inspect the actual rebuilt deliverables, when supplied.
            // Ancient checks run their content registration in this isolated
            // process; no game installation or saves are changed.
            foreach (var modId in OS.GetCmdlineUserArgs())
            {
                var modDir = ProjectSettings.GlobalizePath($"res://../../exports/{modId}");
                Check($"{modId}: mounts delivered PCK", ProjectSettings.LoadResourcePack($"{modDir}/{modId}.pck"));
                var context = AssemblyLoadContext.GetLoadContext(typeof(ModelRuntimeTest).Assembly)!;
                var assembly = context.LoadFromAssemblyPath($"{modDir}/{modId}.dll");
                int characters = 0;
                foreach (var type in assembly.GetTypes())
                {
                    if (type.IsAbstract || !typeof(CharacterModel).IsAssignableFrom(type)) continue;
                    var delivered = (CharacterModel)Activator.CreateInstance(type)!;
                    CheckIndependentCharacter(delivered);
                    Check($"{modId}/{type.Name}: actual selection icon", delivered.CharacterSelectIcon.GetWidth() > 0);
                    Check($"{modId}/{type.Name}: actual locked icon", delivered.CharacterSelectLockedIcon.GetWidth() > 0);
                    Check($"{modId}/{type.Name}: actual map marker", delivered.MapMarker.GetWidth() > 0);
                    CheckAncientDialogues(modId, assembly, delivered);
                    characters++;
                }
                Check($"{modId}: contains registered character classes", characters > 0);
            }
            GD.Print($"===== MODEL RUNTIME PASSED ({_checks} checks) =====");
            GetTree().Quit();
        }
        catch (Exception ex)
        {
            GD.PrintErr(ex.ToString());
            GD.PrintErr("===== MODEL RUNTIME FAILED =====");
            GetTree().Quit(1);
        }
    }
}
