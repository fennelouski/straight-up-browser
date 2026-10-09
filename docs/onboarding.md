# Getting Started Guide

First launch offers **Show me around**, **Maybe later**, and **I’m ready to explore**.
Maybe later waits three days before offering again. Declining or finishing stops automatic
invitations. **Help → Getting Started Guide** always reopens it. Pausing or closing its
browser window saves the chosen path, step, and interests. One browser window owns the
guide at a time. No guide appears in normal UI tests; dedicated onboarding tests opt in.

## Paths

- Quick Start: one page of live keyboard bindings, alternative omnibar commands,
  the full shortcut reference, an explicit memory-saving choice, and an optional
  default-browser action. Large displays include window-position shortcuts.
- Quick Customization: interests, tab layout and maximum page brightness, navigation,
  two-to-four-pane splits, window placement on large displays, memory saving,
  external-agent permissions, and screenshot tools when relevant.
- Deep Dive: navigation, workspaces, captured sources, documents and evidence,
  splits and windows, appearance, memory, download location, on-device translation,
  Newspaper, optional AI setup, external-agent permissions, and relevant screenshot tools.

Interests stay local. A dark browser in the evening/night prioritizes the white-point
explanation. Display size comes from the browser’s actual window screen. Every shortcut
is read from ShortcutStore, including safe alternative bindings. Download-folder choice
uses DownloadFolderAccess and its security-scoped bookmark; leaving it unchanged uses
the existing system Downloads default.

Settings controls write the same preferences as Settings. No AI account is created,
no provider is connected, and no CLI/MCP permission is granted automatically. The user
chooses AI features and then reviews their own provider setup. External agent access
opens the existing Security permission controls; it does not silently grant page-reading,
script, screenshot, or real-event capabilities.

## Motion and interaction

The astronaut remains beside the explanation, using welcome, pointing, and completion
poses. The shuttle flies and rotates toward real view anchors with ease-in/out timing,
then gently floats. Larger targets receive an animated spotlight. The guide never blocks
input outside its card after the initial invitation. Try buttons minimize the card so the
feature remains usable, with a resume chip beside the astronaut. Guide options can disable
all animation or spring motion separately. System Reduce Motion overrides both.
The translation-pack prompt waits while the guide is active; users can review packs from
the translation lesson instead. First-run EULA handling remains in the app delegate.

## Generated artwork

Built-in image_gen was used, with transparent backgrounds preserved. Assets are saved in
`Straight Up Browser/Assets.xcassets/OnboardingAstronautWelcome.imageset`,
`OnboardingAstronautPoint.imageset`, `OnboardingAstronautCelebrate.imageset`, and
`OnboardingShuttle.imageset`. Each PNG is accompanied by its catalog Contents.json.
The pointing and completion poses use the welcome artwork as an identity reference.

Prompt set (production descriptions):

1. Welcome: “Use case: illustration-story. Asset type: transparent mascot PNG for a macOS
browser onboarding guide. Primary request: one friendly astronaut welcoming the user,
full body, waving with one hand, standing in a gently floating relaxed pose. Style:
polished soft 3D clay illustration, compact rounded proportions, warm and approachable
but restrained enough for a desktop productivity app. White space suit with subtle blue
accents, dark navy reflective visor, small backpack, clean readable silhouette, soft studio
light. Entire character visible with generous transparent padding; isolated on truly
transparent background. No floor, no stars, no text, no logos, no watermark. This is the
first pose in a matching guide character set.”
2. Pointing: “Use case: identity-preserve. Asset type: second transparent PNG pose of the
same onboarding astronaut. Preserve exactly this astronaut’s proportions, white clay suit,
blue cuffs and accents, dark navy visor, materials and lighting. Change only the pose: the
astronaut turns slightly to the right and extends one gloved arm to point to the right, as
if explaining a browser feature. Full body entirely visible, centered, generous transparent
padding, same friendly soft 3D style. Truly transparent background with NO surrounding glow,
halo, floor, gradient, shadow rectangle, stars, text or logos. Match the character identity.”
3. Completion: “Use case: identity-preserve. Third pose of the exact same friendly soft 3D
white-and-blue onboarding astronaut. Keep character proportions, suit, blue cuffs and panels,
navy visor, lighting and materials identical. Change only the pose: one hand gives an
enthusiastic but gentle thumbs up, feet floating slightly apart, relaxed full body celebratory
pose. Entire character visible with padding. Truly transparent background; no surrounding
glow or gradient, no floor, stars, words, logos or watermark.”
4. Shuttle: “Use case: illustration-story. Asset type: small transparent PNG space shuttle
mascot that flies around a macOS browser onboarding guide and points at controls. One compact
friendly reusable white space shuttle with blue wing accents and a dark navy cockpit, softly
rounded 3D clay illustration, clean readable silhouette, matching a white-and-blue clay
astronaut. View from above with slight 3D perspective, NO rocket boosters or external tank.
Nose points straight UP, symmetric short swept wings, two small blue engine glows at tail.
Full spacecraft centered with generous padding. Truly transparent background; no halo,
starfield, ground, text, logos, watermark or spotlight (spotlight is drawn by UI code).
Polished restrained desktop-product illustration.”

## Mascot variations (2.9.20)

The guide adds curious, explaining, and floating astronaut poses, selected by lesson.
The tablet pose is excluded. The existing engine-on shuttle is preserved, with a matching
engine-off sibling. Jets crossfade on during each 700 ms flight and off when it settles;
a new destination cancels the previous shutdown. Exhaust uses twelve fading dots in a
70 × 110 Canvas at at most 30 fps. The timeline only exists during a flight, with no
browser-wide state updates. Turning animation off or enabling Reduce Motion hides jets
and removes the particle timeline. Idle floating remains local to the mascot.

New transparent PNG assets, generated with built-in image_gen and copied without alpha edits:

- `Straight Up Browser/Assets.xcassets/OnboardingShuttleOff.imageset/OnboardingShuttleOff.png`
- `Straight Up Browser/Assets.xcassets/OnboardingAstronautCurious.imageset/OnboardingAstronautCurious.png`
- `Straight Up Browser/Assets.xcassets/OnboardingAstronautExplain.imageset/OnboardingAstronautExplain.png`
- `Straight Up Browser/Assets.xcassets/OnboardingAstronautFloat.imageset/OnboardingAstronautFloat.png`

Production prompts (shuttle uses the existing shuttle as the edit target; astronaut poses
use the welcome astronaut as the identity reference):

1. Use case: precise-object-edit. Edit target: existing white-and-blue clay onboarding space shuttle. Make an engine-OFF sprite. Change ONLY the two blue engine flames/glows: remove their light and exhaust completely, leaving clean dark navy engine nozzle interiors. Preserve the exact ship silhouette, nose-up orientation, proportions, white panels, blue wings, dark cockpit, lighting, position and transparent padding. Same canvas and framing, suitable for crossfading with the existing sprite without a jump. Truly transparent background, no surrounding glow, no particles, no text.

2. Use case: identity-preserve. Reference image: existing onboarding astronaut, exact character identity and materials. Create a new full-body transparent PNG pose of this same rounded white clay astronaut with blue cuffs, blue suit panels, navy reflective visor and small backpack. Keep the same proportions and soft studio lighting, entire character visible with generous transparent padding. No surrounding halo, no gradient, no floor, no stars, no text, no logos or watermark. Truly transparent background. Pose: curious, one gloved hand resting thoughtfully against the helmet's chin, head slightly tilted, other hand on hip, friendly inquisitive stance. No extra objects.

3. Use case: identity-preserve. Reference: exact existing white-and-blue clay onboarding astronaut. Create a new full-body pose of the same character: one open gloved hand extended toward the left in a relaxed presenting gesture, other hand resting at its side, helmet turned slightly left toward what it is explaining. Preserve matching compact proportions, white suit, blue cuffs and panels, navy reflective visor, backpack, materials and studio lighting. Entire character visible with generous transparent padding. No tablet or other props, no surrounding glow, no gradient, floor, text, stars or logos. Truly transparent background.

4. Use case: identity-preserve. Reference image: existing onboarding astronaut, exact character identity and materials. Create a new full-body transparent PNG pose of this same rounded white clay astronaut with blue cuffs, blue suit panels, navy reflective visor and small backpack. Keep the same proportions and soft studio lighting, entire character visible with generous transparent padding. No surrounding halo, no gradient, no floor, no stars, no text, no logos or watermark. Truly transparent background. Pose: weightlessly floating at a slight diagonal, knees gently bent, one open gloved hand gesturing toward the right, other arm slightly outward for balance. Friendly relaxed zero-gravity pose, entire body visible.
