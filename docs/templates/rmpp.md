# reMarkable templates

The daily journal references a built-in device template by name — the device
renders it, nothing template-related is uploaded. Set the template with the
`TEMPLATE_STYLE` env var, which accepts either a friendly alias or any raw
template name from the tables below:

| Alias | Template value |
|-------|----------------|
| `blank` | `Blank` |
| `lined` | `P Lines medium` |
| `grid` | `P Grid medium` |
| `checklist` | `P Checklist` |

Any other value is passed through verbatim, so you can use any template here —
e.g. `TEMPLATE_STYLE="P Dots S"` or `TEMPLATE_STYLE="P Cornell"`. The value is
the **filename** column below (exactly, including spaces and capitalisation).

Daily journals are portrait, so prefer the **Portrait** templates. Landscape
(`LS …`) templates are listed for completeness.

> Source: `/usr/share/remarkable/templates/templates.json` from reMarkable
> `rmpp` firmware `3.27.1.0`. Auto-generated — do not edit by hand;
> run scripts/generate-template-docs.sh. The set can differ across firmware.

## Portrait templates

| Name | Template value (`TEMPLATE_STYLE`) | Categories |
|------|-----------------------------------|------------|
| Blank | `Blank` | Creative, Lines, Grids, Planners |
| One storyboard | `P One storyboard` | Creative |
| Two storyboards | `P Two storyboards` | Creative |
| Four storyboards | `P Four storyboards` | Creative |
| Checklist | `P Checklist` | Planners |
| Cornell | `P Cornell` | Lines |
| Day planner | `P Day` | Planners |
| Dots bottom | `P Dots S bottom` | Creative, Grids |
| Dots top | `P Dots S top` | Creative, Grids |
| Dots small | `P Dots S` | Creative, Grids |
| Dots large | `P Dots large` | Creative, Grids |
| Grid bottom | `P Grid bottom` | Grids |
| Grid large | `P Grid large` | Grids |
| Grid medium | `P Grid medium` | Grids |
| Grid small | `P Grid small` | Grids |
| Grid margin large | `P Grid margin large` | Grids |
| Grid margin | `P Grid margin med` | Grids |
| Grid top | `P Grid top` | Grids |
| Lined bottom | `P Lined bottom` | Lines |
| Lined heading | `P Lined heading` | Lines |
| Lined top | `P Lined top` | Lines |
| Lined large | `P Lines large` | Lines |
| Lined medium | `P Lines medium` | Lines |
| Lined small | `P Lines small` | Lines |
| Margin large | `P Margin large` | Lines |
| Margin medium | `P Margin medium` | Lines |
| Margin small | `P Margin small` | Lines |
| US College | `P US College` | Lines |
| US Legal | `P US Legal` | Lines |
| Week planner 1 | `P Week` | Planners |
| Week planner 2 | `P Week 2` | Planners |
| Week planner US | `P Week US` | Planners |
| Isometric | `Isometric` | Creative |
| Perspective 1 | `Perspective1` | Creative |
| Perspective 2 | `Perspective2` | Creative |
| Calligraphy large | `P Calligraphy large` | Creative, Lines |
| Calligraphy medium | `P Calligraphy medium` | Creative, Lines |
| Music | `Notes` | Lines, Creative |
| Bass tabs | `P Bass tab` | Creative |
| Guitar chords | `P Guitar chords` | Creative |
| Guitar tabs | `P Guitar tab` | Creative |
| Piano sheet large | `P Piano sheet large` | Creative |
| Piano sheet medium | `P Piano sheet medium` | Creative |
| Piano sheet small | `P Piano sheet small` | Creative |
| Hexagon large | `P Hexagon large` | Grids |
| Hexagon medium | `P Hexagon medium` | Grids |
| Hexagon small | `P Hexagon small` | Grids |

## Landscape templates

| Name | Template value (`TEMPLATE_STYLE`) | Categories |
|------|-----------------------------------|------------|
| Checklist double | `LS Checklist double` | Planners |
| Checklist | `LS Checklist` | Planners |
| Day planner | `LS Dayplanner` | Planners |
| Dots bottom | `LS Dots bottom` | Creative, Grids |
| Dots top | `LS Dots top` | Creative, Grids |
| Grid bottom | `LS Grid bottom` | Grids |
| Grid margin large | `LS Grid margin large` | Grids |
| Grid margin | `LS Grid margin med` | Grids |
| Grid top | `LS Grid top` | Grids |
| Lined bottom | `LS Lines bottom` | Lines |
| Lined medium | `LS Lines medium` | Lines |
| Lined small | `LS Lines small` | Lines |
| Lined top | `LS Lines top` | Lines |
| Margin medium | `LS Margin medium` | Lines |
| Margin small | `LS Margin small` | Lines |
| One storyboard 1 | `LS One storyboard` | Creative |
| One storyboard 2 | `LS One storyboard 2` | Creative |
| Two storyboards | `LS Two storyboards` | Creative |
| Four storyboards | `LS Four storyboards` | Creative |
| Week planner US | `LS Week US` | Planners |
| Week planner | `LS Week` | Planners |
| Calligraphy large | `LS Calligraphy large` | Creative, Lines |
| Calligraphy medium | `LS Calligraphy medium` | Creative, Lines |
| Piano sheet large | `LS Piano sheet large` | Creative |
| Piano sheet medium | `LS Piano sheet medium` | Creative |
| Piano sheet small | `LS Piano sheet small` | Creative |
