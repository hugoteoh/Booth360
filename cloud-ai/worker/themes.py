"""Visual briefs shared by the cloud generation steps."""

from dataclasses import dataclass


@dataclass(frozen=True)
class Theme:
    wardrobe: str
    scene: str
    landmarks: str
    ending: str


THEMES = {
    "shanghai": Theme(
        "a fitted burgundy velvet qipao with a high collar, champagne-gold piping and frog buttons",
        "a rain-wet 1930s Shanghai Bund hotel entrance, amber lamps and teal shadows",
        "window frames evolve into the brass Art Deco doors and stone pillars; the floor becomes rain-wet stone",
        "lift a single closed black silk fan from the hip with the right hand and unfold it at the waist",
    ),
    "elf": Theme(
        "a layered emerald and ivory woodland robe with embroidered sleeves and a fine silver leaf circlet",
        "an old-growth forest with a mossy stone arch, ferns, filtered sunlight and thin mist",
        "window and wall uprights become tree trunks and the stone arch; the floor becomes a mossy path",
        "turn the right palm upwards near the waist and gather a small warm light above it",
    ),
    "disco": Theme(
        "a champagne-gold sequin jacket with a black collar, black flared trousers and period shoes",
        "an 1980s Hong Kong disco with a mirror ball, warm pink and gold lighting and colorful dance-floor tiles",
        "room columns and ceiling fixtures evolve into disco lighting and the mirror ball; the floor becomes lit tiles",
        "finish with a small step and one hand pointing upward toward the mirror ball",
    ),
}


def wardrobe_prompt(theme):
    return (
        "Edit the reference photograph as a realistic portrait. Preserve this exact person, face, glasses, "
        "hair color, body shape, pose, camera angle and scale. Keep their arms relaxed below the waist. "
        f"Change the clothing to {theme.wardrobe}. The same real venue, lighting, floor and fixed background "
        "are still visible. Preserve existing event marks, without adding lettering or props. Full portrait 9:16."
    )


def tail_prompt(theme):
    return (
        "The first image is the identity and camera-framing reference. The second image shows the same person in "
        f"the finished clothes. Keep their face, hair color, glasses and body proportions. Keep {theme.wardrobe}. "
        f"Place the person in {theme.scene}. In a late frontal three-quarter view, {theme.ending}. "
        "Maintain realistic anatomy, lighting and full portrait framing. Keep existing event overlay marks "
        "in the same positions and add no marks or signage."
    )


def video_prompt(theme, direction, times, guide_order):
    start_edge = "right" if direction == "left" else "left"
    front, scene, ending = times
    return (
        "One uninterrupted eight-second photoreal camera orbit around the person in the first frame. "
        "Preserve their identity, proportions, glasses, hair color, and position. "
        f"{guide_order} Use the same camera direction as the real opening, with fixed objects moving "
        f"from screen {start_edge} to {direction}. Continue from near side to first front, far profile, back "
        "and then towards the face again. Keep hands relaxed and low through the transformation. "
        f"At the FIRST clear front view, near {front:.2f}s, reveal {theme.wardrobe} from the collar and "
        "shoulders down the sleeves and bodice. Show the changing fabric while the original venue is still visible. "
        f"Later, near {scene:.2f}s at the far profile moving towards the back, introduce {theme.scene}. "
        f"Specifically, {theme.landmarks}. Carry camera perspective, clothing, and hand position through the "
        "transition with no cut, flash, reversal, or abrupt gesture. Continue around the back. "
        f"Only near {ending:.2f}s while coming back towards the face, {theme.ending}. "
        "Finish at the supplied tail pose with the camera easing to a stop. Keep original event overlay "
        "marks in place; add no lettering, graphics, or logos."
    )
