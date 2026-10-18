# Cuse interface

A light, native-feeling macOS design. White surfaces, soft gray fills, hairline borders, the system font, and one indigo accent. Cuse sits on top of other apps, so every floating surface is a near-opaque white card with a soft shadow that reads on both light and dark wallpapers.

## Principles

1. **One accent.** Indigo marks the selected mode, the primary action, and the live state. Everything else is neutral. Green means granted or done, amber means needs attention, red is destructive.
2. **Quiet structure.** Rows sit in white cards with a 1pt hairline. Fills are soft gray. Shadows are reserved for floating panels.
3. **Readable first.** Every text/background pair below meets WCAG AA (4.5:1 or better); the measured ratio is next to each token in `DesignSystem.swift`.
4. **Native cues.** Controls use the pointing-hand cursor. Text fields use the I-beam. A press scales to 0.98. State changes take 0.15s.

## Color

| Token | Hex | Use | Contrast |
| --- | --- | --- | --- |
| `background` | `#FFFFFF` | Panels, windows, cards, inputs | n/a |
| `surface1` | `#F5F5F7` | Sidebar, footers, key cards, idle toggles | n/a |
| `surface2` / `surface3` / `surface4` | `#EDEDF0` / `#E4E4E9` / `#D9D9E0` | Hover, pressed, tracks | n/a |
| `borderSubtle` | `#E2E2E8` | Hairlines and card borders | n/a |
| `borderStrong` | `#C7C7D1` | Hover border, unselected radio | n/a |
| `textPrimary` | `#1D1D1F` | Titles and body | 16.8:1 on white |
| `textSecondary` | `#55555F` | Supporting sentences | 7.4:1 |
| `textTertiary` | `#6B6B76` | Captions, idle icons | 5.3:1 |
| `accent` | `#4F46E5` | Primary fill, selected state, links | 6.3:1 on white; white on it 6.3:1 |
| `accentHover` / `accentPressed` | `#4338CA` / `#3730A3` | Primary button states | white on them 7.9:1 / 9.9:1 |
| `accentSubtle` | `#EEF0FF` | Selected row or toggle wash | accent on it 5.6:1 |
| `accentBorder` | `#C7CBFA` | Border of a selected wash | n/a |
| `secondaryMark` | `#0E7490` | Detected text boxes that are not the target | 5.4:1 |
| `success` | `#15803D` | Allowed, saved, done | 5.0:1 |
| `warning` | `#B45309` | Needs attention | 5.0:1 |
| `destructive` | `#DC2626` | Destructive fill (white text 4.8:1) | text form `#B91C1C`, 6.5:1 |

The on-screen pointer is a white arrow with an indigo edge and glow, so it shows on any desktop.

## Type

The macOS system font (SF Pro). Titles are semibold, controls medium, supporting text regular. Small uppercase labels use light tracking (+6%). There is no italic.

| Role | Weight | Size |
| --- | --- | --- |
| Page title | Semibold | 24 |
| Panel title | Semibold | 15–20 |
| Body / row title | Regular / Medium | 13–15 |
| Supporting | Regular | 11–12 |
| Label | Medium, uppercase | 10 |

## Shape

Corner radii: 6 (small controls), 8 (buttons, inputs, overlay labels), 12 (cards, command panel), 14 (menu panel). Capsules for status badges and the Speak / Type / Highlight choices.

## Surfaces

- **Menu panel (360pt).** White header with the pointer mark, Cuse, a status badge (dot and word), pin and close. White body. Soft-gray footer with Settings, Logs and Quit under a hairline. One indigo primary button. Control toggles are rounded tiles that take the indigo wash when on. Permission rows show a green Allowed or an indigo Allow button.
- **Command panel (380pt).** A white rounded card with a hairline and shadow. An indigo pointer mark, a 15pt field, and a gray Stop square while running. The activity line sits below with an indigo dot while active.
- **Decision list.** Step number, controls seen, time and tokens in one row. Done and absent are 4pt capsule gauges (green and amber). Each candidate is a name, a 4pt capsule track and a number; the chosen row is indigo, the others are teal.
- **Speak / Type / Highlight.** Capsules at the cursor. The one under the pointer is indigo with white text; the others are white with a hairline.
- **Settings.** A soft-gray sidebar with an indigo-washed selection, and a white content area. Each section is one white card of rows separated by hairlines. Rows have a tinted icon tile, a title, a supporting line, and a switch or an Allow / Allowed control.
- **Logs.** A soft-gray header with a rounded filter, Readable / Raw segments (the active one is indigo-washed) and indigo text actions over a white monospace body.
- **On-screen labels.** White cards (97% opaque) with a hairline and shadow: the welcome hint, the pointer bubble, the spoken reply, and the listening capsule.

## Files

| File | What it owns |
| --- | --- |
| `Cuse/UI/DesignSystem.swift` | Color, type, corners, button styles, field and overlay-label chrome, cursors |
| `Cuse/UI/CompanionPanelView.swift` | Menu panel |
| `Cuse/UI/ProviderSetupView.swift` | Mode cards and the key card, shared with Settings |
| `Cuse/UI/CuseSettingsView.swift` | Settings |
| `Cuse/UI/TextCommandPanelView.swift` | Command panel |
| `Cuse/Jev/JevStepPanelView.swift` | Live decision list |
| `Cuse/UI/RadialInputSwitcherView.swift` | Speak / Type / Highlight choice |
| `Cuse/UI/OverlayWindow.swift` | Pointer, listening capsule, hint labels |
| `Cuse/UI/CompanionResponseOverlay.swift` | Spoken reply |
| `Cuse/UI/DetectionOverlayView.swift` | Debug detection boxes |
| `Cuse/UI/CuseSettingsWindowManager.swift` | Settings and logs windows |
