import tables,os,strutils,sequtils

## Holds configuration data for all slots which supports tournaments.

type
    SlotTournamentData* = ref object of RootObj
        botSpan*: float
        botScores*: seq[int]
        botProbs*: seq[float]
        tournamentNames*: seq[string]
        tutorialTournamentName*: string

proc `$`*(std: SlotTournamentData): string =
    result = """
        botSpan: $#,
        botScores: $#,
        botProbs: $#,
        tournamentNames: $#
    """.format($std.botSpan, $std.botScores, $std.botProbs, $std.tournamentNames)

var slots* = {
    "dreamTowerSlot": SlotTournamentData(
        botSpan: 5,
        botScores: @[0, 1, 2, 3, 4, 8, 10, 20, 30, 40],
        botProbs: @[0.73, 0.09, 0.06, 0.04, 0.05, 0.0092, 0.0136, 0.00, 0.013, 0.0013],
        tournamentNames: @[
            "Eiffel Tower’s Event",
            "Artist’s Event",
            "Mademoiselle’s Event",
            "Sommelier's Event",
            "Scatter’s Event",
            "Tourist’s Event",
            "Dove’s Event",
            "Wild’s Event",
            "Lift Attendant's Event",
            "Garçon’s Event",
            "Chef’s Event",
            "Mime’s Event"],
        tutorialTournamentName: "Mime Challenger",
    ),
    "balloonSlot": SlotTournamentData(
        botSpan: 9,
        botScores: @[0, 1, 2, 3, 4, 8, 10, 20, 30, 40],
        botProbs: @[0.72, 0.07, 0.06, 0.04, 0.06, 0.01, 0.0255, 0.007, 0.0033, 0.0042],
        tournamentNames: @[
            "Calm Event",
            "Breezy Event",
            "Draft Event",
            "Gust Event",
            "Monsoon Event",
            "Tropical Storm Event",
            "Windy Event",
            "Flurry Event",
            "Gale Event",
            "Storm Event",
            "Cyclone Event",
            "Hurricane Event"],
        tutorialTournamentName: "Helium Challenger",
    ),
    "candySlot": SlotTournamentData(
        botSpan: 5,
        botScores: @[0, 1, 2, 3, 4, 8, 10, 20],
        botProbs: @[0.76, 0.1, 0.065, 0.011, 0.024, 0.008, 0.025, 0.007],
        tournamentNames: @[
            "Bubble Gum Event",
            "Candy Cane Event",
            "Fudge Event",
            "Jawbreaker Event",
            "Pez Event",
            "Taffy Event",
            "Cotton Candy Event",
            "Cupcake Event",
            "Gummi Bear Event",
            "Lollipop Event",
            "Licorice Event",
            "Marshmallow Event"],
        tutorialTournamentName: "Squib Challenger",
    ),
    "witchSlot": SlotTournamentData(
        botSpan: 5,
        botScores: @[0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 15],
        botProbs: @[0.6, 0.28, 0.018, 0.057, 0.013, 0.0106, 0.004, 0.0036, 0.0025, 0.004, 0.003, 0.0043],
        tournamentNames: @[
            "Flying Broom Event",
            "Magic Spell Event",
            "Talking Wart Event",
            "Pointy Hat Event",
            "Slimy Toad Event",
            "Witching Hour Event",
            "Magic Wand Event",
            "Hocus-Pocus Event",
            "Love Potion Event",
            "Black Cat Event",
            "Bubbling Cauldron Event",
            "Book of Shadows Event"],
        tutorialTournamentName: "Spinner Challenger",
    ),
    "mermaidSlot": SlotTournamentData(
        botSpan: 5,
        botScores: @[0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 15],
        botProbs: @[0.84, 0.048, 0.017, 0.012, 0.011, 0.006, 0.01, 0.0056, 0.011, 0.0097, 0.0088, 0.012],
        tournamentNames: @[
            "Starfish Event",
            "Dolphin Event",
            "Sea Turtle Event",
            "Sea Horse Event",
            "Neptune Event",
            "Pearl Event",
            "Necklace Event",
            "Fin Event",
            "Goldfish Event",
            "Ship Event",
            "Prince Event",
            "Treasure Chest Event"],
        tutorialTournamentName: "Crucian Challenger",
    ),
}.toTable()

# if getEnv("FALCON_ENV") == "stage":
#     ## For testing new slots which are not in production.
#     let stageSlots = {
#     }.toTable()

#     for key, value in stageSlots.pairs:
#         slots.add(key, value)

echo "Tournaments enabled for slots ", toSeq(slots.keys)
