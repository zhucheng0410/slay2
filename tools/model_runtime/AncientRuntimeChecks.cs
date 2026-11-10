using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Text.Json;
using Godot;
using MegaCrit.Sts2.Core.Entities.Ancients;
using MegaCrit.Sts2.Core.Entities.Cards;
using MegaCrit.Sts2.Core.Localization;
using MegaCrit.Sts2.Core.Models;
using STS2RitsuLib.Content;
using STS2RitsuLib.Localization;

public partial class ModelRuntimeTest
{
    private void CheckAncientDialogues(string modId, Assembly assembly, CharacterModel character)
    {
        var locales = new[] { "zhs", "eng", "deu", "esp", "fra", "ita", "jpn", "kor", "pol", "ptb", "rus", "spa", "tha", "tur" };
        var ancients = new[] { "NEOW", "DARV", "PAEL", "OROBAS", "NONUPEIPE", "TEZCATARA", "TANX", "VAKUU", "THE_ARCHITECT" };
        // The regular LocManager constructor reads SaveManager. Supply only
        // its in-memory tables in this test process, never opening game saves.
        var manager = (LocManager)RuntimeHelpers.GetUninitializedObject(typeof(LocManager));
        typeof(LocManager).GetProperty("Instance")!.SetValue(null, manager);
        var entry = ModContentRegistry.GetFixedPublicEntry(modId, character.GetType());
        var id = new ModelId("character", entry);
        // Use the real RitsuLib naming API, independent of the exporter. The
        // isolated host has no global ModelDb identity Harmony patch installed.
        var fixture = (CharacterModel)RuntimeHelpers.GetUninitializedObject(character.GetType());
        typeof(AbstractModel).GetField("<Id>k__BackingField", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(fixture, id);
        foreach (var locale in locales)
        {
            var tables = new Dictionary<string, LocTable>();
            foreach (var name in new[] { "ancients", "cards", "characters", "relics" })
            {
                string path = $"res://{modId}/localization/{locale}/{name}.json";
                if (!Godot.FileAccess.FileExists(path)) continue;
                var json = JsonSerializer.Deserialize<Dictionary<string, string>>(Godot.FileAccess.GetFileAsString(path))!;
                tables[name] = new LocTable(name, json);
            }
            typeof(LocManager).GetField("_tables", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(manager, tables);
            foreach (var ancient in ancients)
            {
                var set = new AncientDialogueSet {
                    FirstVisitEverDialogue = null,
                    AgnosticDialogues = Array.Empty<AncientDialogue>(),
                    CharacterDialogues = new Dictionary<string, IReadOnlyList<AncientDialogue>>()
                };
                int added = AncientDialogueLocalization.AppendCharacterDialogues(set, ancient, new[] { fixture });
                if (added != 2) throw new InvalidOperationException($"{modId}/{locale}/{ancient}: expected 2 registered dialogues, got {added}, entry={entry}");
                set.PopulateLocKeys(ancient);
                foreach (var dialogue in set.CharacterDialogues[entry])
                {
                    if (dialogue.Lines.Count == 0) throw new InvalidOperationException("Empty dialogue");
                    for (int i = 0; i < dialogue.Lines.Count; i++)
                    {
                        var line = dialogue.Lines[i];
                        if (string.IsNullOrWhiteSpace(line.LineText?.GetRawText())) throw new InvalidOperationException("Missing line text");
                        if (i + 1 < dialogue.Lines.Count && string.IsNullOrWhiteSpace(line.NextButtonText?.GetRawText())) throw new InvalidOperationException("Missing continue button");
                        if (i + 1 == dialogue.Lines.Count && line.NextButtonText != null) throw new InvalidOperationException("Final line incorrectly continues");
                    }
                }
                foreach (int visits in new[] { 0, 1, 2, 4, 20, 999 })
                {
                    var available = set.GetValidDialogues(id, visits, Math.Max(1, visits), false).ToList();
                    if (available.Count == 0) throw new InvalidOperationException($"Empty selection at visit {visits}");
                    if (visits > 0 && available.Any(x => !x.IsRepeating)) throw new InvalidOperationException("Lost repeat marker");
                    if (ancient == "THE_ARCHITECT" && available.Any(x => x.StartAttackers != ArchitectAttackers.None || x.EndAttackers != ArchitectAttackers.Both)) throw new InvalidOperationException("Architect completion metadata missing");
                }
                if (set.GetValidDialogues(new ModelId("character", "OTHER"), 0, 1, false).Any()) throw new InvalidOperationException("Dialogue leaked to another character");
                var firstEver = new AncientDialogue("");
                var globalSet = new AncientDialogueSet { FirstVisitEverDialogue = firstEver, AgnosticDialogues = Array.Empty<AncientDialogue>(), CharacterDialogues = set.CharacterDialogues };
                if (!ReferenceEquals(globalSet.GetValidDialogues(id, 0, 0, false).Single(), firstEver)) throw new InvalidOperationException("Global introduction overwritten");
            }
            Check($"{modId}/{locale}: all 9 Ancient dialogues resolve text/buttons, repeat at visits 1–999, isolate characters and preserve first-ever priority", true);
        }
        // Exercise the generated registration, and RitsuLib's actual candidate
        // filter (which ignores ordinary cards even when explicitly registered).
        var englishTables = new Dictionary<string, LocTable>();
        foreach (var name in new[] { "ancients", "cards", "characters", "relics" })
        {
            string path = $"res://{modId}/localization/eng/{name}.json";
            if (Godot.FileAccess.FileExists(path)) englishTables[name] = new LocTable(name, JsonSerializer.Deserialize<Dictionary<string, string>>(Godot.FileAccess.GetFileAsString(path))!);
        }
        typeof(LocManager).GetField("_tables", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(manager, englishTables);
        assembly.GetType(modId + ".ModEntry")!.GetMethod("Initialize")!.Invoke(null, null);
        foreach (var type in assembly.GetTypes().Where(t => !t.IsAbstract && typeof(CardModel).IsAssignableFrom(t))) ModelDb.Inject(type);
        var registry = typeof(AncientDialogueLocalization).Assembly.GetType("STS2RitsuLib.Relics.DustyTomeCardRegistry")!;
        var args = new object?[] { ModelDb.GetId(character.GetType()), null };
        bool found = (bool)registry.GetMethod("TryGetPreferredCards", BindingFlags.Static | BindingFlags.NonPublic)!.Invoke(null, args)!;
        var cards = args[1] as IReadOnlyList<CardModel>;
        Check($"{modId}: generated registration supplies real Ancient Tome candidates", found && cards != null && cards.Count > 0 && cards.All(c => c.Rarity == CardRarity.Ancient && c.GetType().Assembly == assembly));
    }
}
