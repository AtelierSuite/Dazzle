// Playing a slide's transition in a slideshow, as the Apple apps play it.
//
// The engine works the effect out (Bridge "transition"): layers, back to
// front, each the slide being left, the slide arriving, or black or white,
// with keyframes for how each is placed, faded and clipped over the effect's
// duration. Here each layer becomes a pair of elements on the stage, and the
// Web Animations API plays the keyframes. A transition is the deck's own
// content rather than the interface's motion, so it plays even when motion is
// reduced, but then as a cross-fade, which the engine is asked for instead.
//
// A Morph also has pairs of shapes the two slides share. Each pair's two
// shapes are copied onto a layer of their own, over the cross-fade of the
// rest, placed in the same spot and dissolving from one to the other.

/** Whether the viewer asks for less motion: transitions then cross-fade. */
export function prefersReducedMotion() {
  return Boolean(window.matchMedia?.("(prefers-reduced-motion: reduce)").matches);
}

export class TransitionPlayer {
  /**
   * @param {HTMLElement} stage what the slide is drawn in
   * @param {(slide: HTMLElement) => void} fit places a slide in the stage, fitted and centred
   */
  constructor(stage, fit) {
    this.stage = stage;
    this.fit = fit;
    this.animations = [];
    this.layers = [];
    this.incoming = null;
  }

  get isPlaying() {
    return this.incoming !== null;
  }

  /**
   * Plays `transition` from the slide element `outgoing` to `incoming`, which
   * is already the stage's slide. Resolves once it has finished or been cut short.
   */
  play(transition, outgoing, incoming) {
    this.finish();
    if (!transition?.layers?.length || !incoming?.slideScene) return Promise.resolve();
    const scene = incoming.slideScene;
    const placement = this.placement(scene);
    this.incoming = incoming;
    const timing = { duration: transition.duration * 1000, fill: "both", easing: "linear" };
    const used = new Set();
    for (const layer of transition.layers) {
      const outer = document.createElement("div");
      outer.className = "slideshow__transition";
      outer.style.width = `${scene.w}px`;
      outer.style.height = `${scene.h}px`;
      outer.style.transform = placement;
      const inner = document.createElement("div");
      inner.className = "slideshow__transition-content";
      let content;
      const source = layer.content === "outgoing" ? outgoing : layer.content === "incoming" ? incoming : null;
      if (source) {
        // A slide shown by more than one layer (a comb's strips) is copied for the rest.
        content = used.has(source) ? source.cloneNode(true) : source;
        used.add(source);
        content.style.transform = "none";
      } else {
        content = document.createElement("div");
        content.className = `slideshow__transition-fill slideshow__transition-fill--${layer.content === "white" ? "white" : "black"}`;
      }
      inner.append(content);
      outer.append(inner);
      this.stage.append(outer);
      this.layers.push(outer);
      this.animations.push(
        outer.animate(layer.keyframes.map(({ offset, opacity, clipPath }) => ({ offset, opacity, clipPath })), timing),
        inner.animate(layer.keyframes.map(({ offset, transform }) => ({ offset, transform })), timing),
      );
    }
    if (transition.morph?.length) this.morph(transition.morph, outgoing, incoming, scene, placement, timing);
    // What else was on the stage, the slide being left included, is now in the layers or gone.
    for (const child of [...this.stage.children]) if (!this.layers.includes(child)) child.remove();
    const animations = this.animations;
    return Promise.all(animations.map((animation) => animation.finished)).then(
      () => { if (this.animations === animations) this.finish(); },
      () => {},
    );
  }

  /** Ends the transition now, leaving the arriving slide on the stage. */
  finish() {
    const incoming = this.incoming;
    const animations = this.animations;
    this.animations = [];
    this.incoming = null;
    for (const animation of animations) animation.cancel();
    for (const layer of this.layers) layer.remove();
    this.layers = [];
    for (const shape of incoming?.querySelectorAll(".is-morphing") ?? []) shape.classList.remove("is-morphing");
    if (incoming) {
      this.stage.replaceChildren(incoming);
      this.fit(incoming);
    }
  }

  /**
   * A Morph's shared shapes on a layer over the others: for each pair, a copy
   * of the shape being left and of the shape arriving, the originals hidden.
   */
  morph(pairs, outgoing, incoming, scene, placement, timing) {
    const layer = document.createElement("div");
    layer.className = "slideshow__transition";
    layer.style.width = `${scene.w}px`;
    layer.style.height = `${scene.h}px`;
    layer.style.transform = placement;
    const find = (slide, id) => [...slide.querySelectorAll(":scope > .shape.is-own")].find((shape) => shape.dataset.id === id);
    for (const pair of pairs) {
      const sides = [[find(outgoing, pair.from), "from"], [find(incoming, pair.to), "to"]];
      if (sides.some(([shape]) => !shape)) continue;
      const group = document.createElement("div");
      group.className = "slideshow__morph";
      for (const [shape, side] of sides) {
        const holder = document.createElement("div");
        holder.className = `slideshow__morph-shape slideshow__morph-shape--${side}`;
        holder.append(shape.cloneNode(true));
        shape.classList.add("is-morphing");
        group.append(holder);
        this.animations.push(holder.animate(pair.keyframes.map((keyframe) => ({
          offset: keyframe.offset, transform: keyframe[side], opacity: side === "to" ? keyframe.mix : 1 - keyframe.mix,
        })), timing));
      }
      layer.append(group);
    }
    this.stage.append(layer);
    this.layers.push(layer);
  }

  /** The stage's transform for a slide of `scene`, fitted and centred, as slideshow.js fits slides. */
  placement(scene) {
    const scale = Math.min(this.stage.clientWidth / scene.w, this.stage.clientHeight / scene.h) || 0;
    return `translate(${(this.stage.clientWidth - scene.w * scale) / 2}px, ${(this.stage.clientHeight - scene.h * scale) / 2}px) scale(${scale})`;
  }
}
