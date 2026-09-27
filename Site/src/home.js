// Emblem homepage film. It runs entirely in the browser: no network requests,
// no storage, no cookies. Every word on the page is ordinary HTML; this module
// paints a scroll-directed WebGL film behind it and fails closed to the static page.
import {
  WebGLRenderer, WebGLRenderTarget, HalfFloatType, Scene, PerspectiveCamera, Color, Vector2, Vector3,
  Group, Mesh, InstancedMesh, InstancedBufferGeometry, InstancedBufferAttribute, PlaneGeometry,
  ShaderMaterial, CanvasTexture, SRGBColorSpace, LinearMipmapLinearFilter, Shape, Path, ExtrudeGeometry,
  CircleGeometry, SphereGeometry, LatheGeometry, MeshPhysicalMaterial, MeshBasicMaterial, PMREMGenerator,
  BoxGeometry, BackSide, BufferGeometry, Float32BufferAttribute, LineSegments, LineBasicMaterial,
  DirectionalLight, AmbientLight, NeutralToneMapping, Raycaster, Euler, DynamicDrawUsage, CustomBlending,
  OneFactor, ZeroFactor, Points, CatmullRomCurve3, Matrix4, Quaternion, DoubleSide,
} from 'three';
import { EffectComposer } from 'three/addons/postprocessing/EffectComposer.js';
import { RenderPass } from 'three/addons/postprocessing/RenderPass.js';
import { UnrealBloomPass } from 'three/addons/postprocessing/UnrealBloomPass.js';
import { OutputPass } from 'three/addons/postprocessing/OutputPass.js';
import { ShaderPass } from 'three/addons/postprocessing/ShaderPass.js';

const TAU = Math.PI * 2;
const clamp = (x, a, b) => Math.min(b, Math.max(a, x));
const lerp = (a, b, t) => a + (b - a) * t;
const smooth = (a, b, x) => { const t = clamp((x - a) / (b - a), 0, 1); return t * t * (3 - 2 * t); };
const smoother = t => t * t * t * (t * (t * 6 - 15) + 10);
const easeOut = t => 1 - Math.pow(1 - clamp(t, 0, 1), 3);
function random(seed) {
  let a = seed >>> 0;
  return () => { a = (a + 0x6D2B79F5) | 0; let t = Math.imul(a ^ (a >>> 15), 1 | a); t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
}

const root = document.documentElement;
const canvas = document.getElementById('scene');
const labelLayer = document.getElementById('labels');
const reduced = matchMedia('(prefers-reduced-motion: reduce)').matches;
const coarse = matchMedia('(pointer: coarse)').matches;

// The app's own monogram palette (NameAvatar.swift), including the slate variant.
const MONOGRAM = [[0.22, 0.30, 0.60], [0.12, 0.40, 0.44], [0.46, 0.24, 0.45], [0.40, 0.31, 0.55], [0.45, 0.32, 0.22], [0.24, 0.36, 0.29]];
const SLATE = [0.28, 0.31, 0.37];
// Invented marks standing in for brand icons. None depicts a real company.
const MARKS = ['#ff5b3a', '#2f6bff', '#ffd23f', '#12b886', '#ff3d8b', '#17181a', '#7a5cff', '#00a2ff', '#ff8a00', '#ecebe4', '#0f9d58', '#e8453c'];
const NIGHT = '#0a0b08';
const ADD = { blending: CustomBlending, blendSrc: OneFactor, blendDst: OneFactor, blendSrcAlpha: ZeroFactor, blendDstAlpha: OneFactor };

// ---------------------------------------------------------------- the film
// One camera path for the whole page. t is act + progress through that act's
// section; p is the camera, l what it looks at, bars the letterbox (0-1).
const SHOTS = [
  { t: 0.00, p: [0, 0.25, 9.6], l: [0.5, 0, 0], fov: 34 },
  { t: 0.30, p: [0.25, 0.15, 9.2], l: [0.7, -0.1, -0.2], fov: 34 },
  { t: 0.62, p: [1.1, -0.2, 8.0], l: [1.1, -0.35, -0.8], fov: 36 },
  { t: 0.94, p: [2.4, -1.0, 5.4], l: [1.3, -0.7, -3.8], fov: 44, bars: 0.4 },
  { t: 1.08, p: [4.3, 1.9, -11.6], l: [1.4, -0.5, -3], fov: 48, bars: 1 },
  { t: 1.34, p: [3.1, 1.1, -7.2], l: [1.35, -0.55, -0.6], fov: 46, bars: 1 },
  { t: 1.58, p: [2.05, 0.1, -1.3], l: [1.35, -0.55, 2.6], fov: 60, bars: 1 },
  { t: 1.84, p: [0.25, 0.5, 7.0], l: [1.2, -0.4, 0], fov: 38, bars: 0.3 },
  { t: 2.04, p: [-0.4, 3.3, 8.8], l: [0.9, -0.5, 0], fov: 34 },
  { t: 2.26, p: [-0.2, 3.0, 8.9], l: [0.9, -0.5, 0], fov: 34 },
  { t: 2.48, p: [6.6, 0.5, 4.6], l: [0.9, -0.55, 0], fov: 38, bars: 0.6 },
  { t: 2.72, p: [5.2, -2.2, -4.4], l: [0.9, -0.55, 0], fov: 40, bars: 0.6 },
  { t: 2.95, p: [-1.2, 1.3, 8.6], l: [0.6, -0.4, 0], fov: 36 },
  { t: 3.05, p: [3.9, 0.6, 8.2], l: [-1.2, -0.3, -0.8], fov: 36 },
  { t: 3.24, p: [3.6, 0.8, 7.8], l: [-1.2, -0.25, -0.8], fov: 36 },
  { t: 3.46, p: [-1.0, 3.8, 2.6], l: [-1.55, 0.2, -0.8], fov: 46, bars: 0.6 },
  { t: 3.68, p: [-1.55, 0.5, -0.8], l: [-1.55, -0.3, -3.7], fov: 74, bars: 1 },
  { t: 3.94, p: [-1.55, -0.95, -0.6], l: [-1.25, 2.9, -1.2], fov: 80, bars: 1, roll: 0.5 },
  { t: 4.05, p: [0.2, 0.4, 8.8], l: [1.4, -0.5, 0], fov: 36 },
  { t: 4.24, p: [0.35, 0.3, 8.6], l: [1.5, -0.55, 0], fov: 36 },
  { t: 4.48, p: [2.0, -0.7, 3.4], l: [2.2, -0.95, 0], fov: 42, bars: 0.4 },
  { t: 4.64, p: [2.2, -0.95, 0.72], l: [2.6, -0.62, 2.6], fov: 70, bars: 1 },
  { t: 4.78, p: [2.18, -0.93, 0.7], l: [2.33, -0.84, 1.16], fov: 68, bars: 1 },
  { t: 4.96, p: [2.8, -0.4, 3.2], l: [2.2, -0.95, 0], fov: 44, bars: 0.3 },
  { t: 5.05, p: [2.4, 1.1, 7.3], l: [0.6, 0, 0], fov: 34 },
  { t: 5.24, p: [2.5, 1.05, 7.2], l: [0.7, 0, 0], fov: 34 },
  { t: 5.48, p: [6.1, 0.8, 3.0], l: [1.6, -0.5, 0], fov: 30, bars: 0.5 },
  { t: 5.74, p: [4.5, -0.3, -3.6], l: [1.6, -0.5, 0], fov: 32, bars: 0.5 },
  { t: 5.95, p: [0.9, 0.6, 7.6], l: [1.1, -0.3, 0], fov: 36 },
  { t: 6.06, p: [0, 0.3, 9.5], l: [0, -0.2, 0], fov: 38 },
  { t: 6.36, p: [0, 1.6, 19.0], l: [0, 2.3, -8], fov: 48, bars: 1 },
  { t: 6.6, p: [0, 1.0, 14], l: [0, 1.6, -6], fov: 44, bars: 1 },
  { t: 6.86, p: [0, 0.1, 8.4], l: [0, -0.4, 0], fov: 36, bars: 0.2 },
  { t: 7.00, p: [0, -0.35, 7.6], l: [0, -0.8, 0], fov: 34 },
];
// Giant headlines are objects in the scene, placed where each shot reads them.
const TYPE = [
  { line: 'A familiar face', at: 0.22, x: -0.84, y: 0.55, d: 6.5, size: 0.16, hero: true, until: 0.72 },
  { line: 'for your inbox.', at: 0.22, x: -0.76, y: 0.34, d: 6.5, size: 0.16, outline: true, hero: true, until: 0.72 },
  { line: 'Envelopes in.', at: 1.3, x: -0.9, y: 0.5, d: 5.2, size: 0.17, from: 1.08, until: 1.5 },
  { line: 'Faces out.', at: 1.85, x: -0.92, y: 0.46, d: 4.6, size: 0.19, outline: true, from: 1.62, until: 2.02 },
  { line: 'Seven places', at: 2.22, x: -0.94, y: 0.52, d: 6, size: 0.16, from: 2.0, until: 2.62 },
  { line: 'to look.', at: 2.22, x: -0.84, y: 0.31, d: 6, size: 0.16, outline: true, from: 2.0, until: 2.62 },
  { line: 'Synced to', at: 3.22, x: 0.05, y: 0.55, d: 6, size: 0.16, from: 3.0, until: 3.42 },
  { line: 'Contacts.', at: 3.22, x: 0.12, y: 0.34, d: 6, size: 0.16, outline: true, from: 3.0, until: 3.42 },
  { line: 'Your inbox isn’t', at: 4.22, x: -0.94, y: 0.52, d: 6, size: 0.15, from: 4.0, until: 4.46 },
  { line: 'our database.', at: 4.22, x: -0.86, y: 0.32, d: 6, size: 0.15, outline: true, from: 4.0, until: 4.46 },
  { line: 'Four layers.', at: 5.22, x: -0.94, y: 0.52, d: 6, size: 0.16, from: 5.0, until: 5.5 },
  { line: 'One lens.', at: 5.22, x: -0.84, y: 0.31, d: 6, size: 0.16, outline: true, from: 5.0, until: 5.5 },
  { line: 'Meet your', at: 6.96, x: -0.52, y: 0.66, d: 6.5, size: 0.17, from: 6.74, until: 9 },
  { line: 'inbox.', at: 6.96, x: -0.26, y: 0.44, d: 6.5, size: 0.17, outline: true, from: 6.74, until: 9 },
];

function start() {
  let renderer;
  try {
    renderer = new WebGLRenderer({ canvas, antialias: true, powerPreference: 'high-performance' });
  } catch { return false; }
  if (!renderer.getContext()) return false;

  const narrow = () => innerWidth < 820 || innerHeight > innerWidth;
  const lowPower = coarse || (navigator.hardwareConcurrency || 8) <= 4;
  let pixelRatio = Math.min(devicePixelRatio || 1, lowPower ? 1.5 : 1.75);
  renderer.setPixelRatio(pixelRatio);
  renderer.toneMapping = NeutralToneMapping;
  renderer.toneMappingExposure = 1.05;
  renderer.outputColorSpace = SRGBColorSpace;
  if ('transmissionResolutionScale' in renderer) renderer.transmissionResolutionScale = lowPower ? 0.5 : 0.75;

  const scene = new Scene();
  scene.background = new Color(NIGHT);
  const camera = new PerspectiveCamera(34, innerWidth / innerHeight, 0.05, 120);
  camera.position.set(0, 0, 9);

  const pmrem = new PMREMGenerator(renderer);
  scene.environment = pmrem.fromScene(studio(), 0.03).texture;
  pmrem.dispose();
  const key = new DirectionalLight('#fff4df', 2.1); key.position.set(-3, 4, 6); scene.add(key);
  const rim = new DirectionalLight('#b9c79a', 2.4); rim.position.set(4, 1.5, -5); scene.add(rim);
  scene.add(new AmbientLight('#2a2d22', 0.9));

  const stars = buildStars(lowPower ? 900 : 2200); scene.add(stars);
  const rays = buildRays(); scene.add(rays);
  const glow = backGlow(); scene.add(glow);
  const icon = buildIcon(); scene.add(icon.group);
  const flare = buildFlare(); scene.add(flare);
  const swarm = buildSwarm(renderer, lowPower ? 1600 : 6000);
  scene.add(swarm.mesh, swarm.bokeh);
  const rings = buildRings(); scene.add(rings);
  const bubble = buildBubble(); scene.add(bubble);
  const wave = buildWave(); scene.add(wave);
  const type = buildType(renderer, lowPower); scene.add(type.group);

  // ---------------------------------------------------------------- post
  const film = new ShaderPass(filmShader());
  let composer = null, bloom = null;
  function buildPost() {
    const target = new WebGLRenderTarget(1, 1, { type: HalfFloatType, samples: lowPower ? 0 : 4 });
    composer = new EffectComposer(renderer, target);
    composer.addPass(new RenderPass(scene, camera));
    bloom = new UnrealBloomPass(new Vector2(innerWidth, innerHeight), lowPower ? 0.45 : 0.62, 0.55, 0.9);
    composer.addPass(bloom);
    composer.addPass(new OutputPass());
    composer.addPass(film);
  }
  buildPost();

  // ---------------------------------------------------------------- labels
  const labels = [];
  function label(text, cls) {
    const el = document.createElement('span');
    el.className = 'tag ' + (cls || '');
    el.textContent = text;
    labelLayer.appendChild(el);
    const item = { el, world: new Vector3(), act: -1, visible: 0 };
    labels.push(item);
    return item;
  }
  const gateTop = label('From · To · Cc · date'); gateTop.act = 1;
  const gateBottom = label('no subjects · no bodies', 'quiet'); gateBottom.act = 1;
  const ringTags = ['directory', 'BIMI', 'brand', 'touch icon', 'website', 'Gravatar', 'monogram'].map(n => { const l = label(n); l.act = 2; return l; });
  const layerTags = ['head', 'glass lens', 'body', 'well', 'background'].map(n => { const l = label(n, 'layer'); l.act = 5; return l; });

  // ---------------------------------------------------------------- the path
  const pathP = new CatmullRomCurve3(SHOTS.map(s => new Vector3(...s.p)), false, 'centripetal', 0.5);
  const pathL = new CatmullRomCurve3(SHOTS.map(s => new Vector3(...s.l)), false, 'centripetal', 0.5);
  function shotAt(T, outP, outL) {
    let i = 0; while (i < SHOTS.length - 2 && SHOTS[i + 1].t <= T) i++;
    const a = SHOTS[i], b = SHOTS[i + 1];
    const s = smoother(clamp((T - a.t) / (b.t - a.t), 0, 1)), u = (i + s) / (SHOTS.length - 1);
    pathP.getPoint(u, outP); pathL.getPoint(u, outL);
    return { fov: lerp(a.fov, b.fov, s), bars: lerp(a.bars || 0, b.bars || 0, s), roll: lerp(a.roll || 0, b.roll || 0, s) };
  }
  // A still, readable frame per act for reduced motion.
  const STILLS = [1, 7, 9, 14, 19, 25, 33].map(i => SHOTS[i]);
  function stillAt(T, outP, outL) { const s = STILLS[clamp(Math.floor(T), 0, 6)]; outP.set(...s.p); outL.set(...s.l); return { fov: s.fov, bars: 0, roll: 0 }; }

  // ---------------------------------------------------------------- scroll
  const sections = [...document.querySelectorAll('[data-act]')];
  let offsets = [];
  function measure() {
    offsets = sections.map(s => { const r = s.getBoundingClientRect(); return { top: r.top + scrollY, height: r.height, act: +s.dataset.act }; }).filter(o => o.height > 0);
  }
  let target = 0, act = 0, pinned = false;
  function readScroll() {
    const probe = scrollY + innerHeight * 0.15;
    let found = offsets[0];
    for (const o of offsets) if (o.top <= probe) found = o;
    if (!found) return;
    if (!pinned) target = found.act + clamp((probe - found.top) / Math.max(1, found.height), 0, 0.999);
    if (!pinned && found.act === 6 && scrollY + innerHeight >= document.documentElement.scrollHeight - 4) target = 7;
    const next = found.act;
    if (next !== act) { act = next; swarm.kick(act); sections.forEach(s => s.classList.toggle('is-active', +s.dataset.act === act)); }
  }

  // ---------------------------------------------------------------- input
  const pointer = new Vector2(0, 0), pointerSmooth = new Vector2(0, 0), pointerNdc = new Vector2(9, 9);
  let pointerSeen = false;
  addEventListener('pointermove', e => {
    pointer.set(e.clientX / innerWidth * 2 - 1, -(e.clientY / innerHeight * 2 - 1));
    pointerNdc.copy(pointer); pointerSeen = true;
  }, { passive: true });
  addEventListener('pointerleave', () => pointerNdc.set(9, 9));
  const raycaster = new Raycaster();
  let flash = 0;
  addEventListener('click', e => {
    if (e.target.closest('a,button,input,select,textarea')) return;
    const at = new Vector2(e.clientX / innerWidth * 2 - 1, -(e.clientY / innerHeight * 2 - 1));
    raycaster.setFromCamera(at, camera);
    const onIcon = raycaster.intersectObject(icon.group, true).length > 0;
    if (onIcon) icon.spin(clock);
    if (onIcon || act === 0 || act === 6) { swarm.shock(clock, at); if (!reduced) flash = 0.35; }
  });
  // Type initials: a monogram is drawn right here, the way Emblem draws one on the Mac.
  let typed = '';
  addEventListener('keydown', e => {
    if (e.metaKey || e.ctrlKey || e.altKey || act !== 0) return;
    if (e.target.closest && e.target.closest('input,textarea,select,[contenteditable]')) return;
    if (/^[a-z]$/i.test(e.key)) { typed = (typed + e.key.toUpperCase()).slice(-2); icon.badge(typed); }
    else if (e.key === 'Backspace' || e.key === 'Escape') { typed = ''; icon.badge(''); }
  });

  // ---------------------------------------------------------------- play the film
  const play = document.querySelector('.play');
  let playing = null;
  function stopFilm() { if (!playing) return; playing = null; root.classList.remove('film'); play.textContent = '▶ Play the film'; }
  if (play && !reduced) {
    play.hidden = false;
    play.addEventListener('click', () => {
      if (playing) return stopFilm();
      playing = { at: performance.now(), from: scrollY };
      root.classList.add('film'); play.textContent = '■ Stop';
    });
    for (const ev of ['wheel', 'touchstart', 'keydown']) addEventListener(ev, e => { if (!(ev === 'keydown' && e.key === 'Enter')) stopFilm(); }, { passive: true });
  }

  // ---------------------------------------------------------------- loop
  let clock = 0, last = performance.now(), running = true, T = 0, lastScroll = scrollY, scrollVel = 0;
  const capture = location.hostname === 'localhost' && new URLSearchParams(location.search).has('capture');
  let frames = 0, frameTime = 0, degraded = 0;
  const camPos = new Vector3(0, 0.25, 9.6), camLook = new Vector3(0.5, 0, 0), wantP = new Vector3(), wantL = new Vector3();
  const lastCam = new Vector3(), tmp = new Vector3(), tmp2 = new Vector3(), vortexPoint = new Vector3();
  let fov = 34, bars = 0, speed = 0;
  const iconState = { p: new Vector3(2.3, -0.8, 0.4), v: new Vector3(), s: 0.9, sv: 0, rx: 0, ry: 0, rxv: 0, ryv: 0, ex: 0, exv: 0 };
  const poses = {
    wide: [[2.3, -0.8, 0.4, 0.9, 0.1, -0.36, 0], [1.35, -0.55, 0, 0.72, 0, -0.12, 0], [0.9, -0.55, 0, 0.78, 0.1, 0, 0], [1.9, -1.7, 0.9, 0.36, 0.12, -0.5, 0], [2.2, -0.95, 0, 0.4, 0, 0, 0], [1.6, -0.5, 0, 0.95, 0.22, -0.9, 1], [0, -1.1, 0.3, 0.82, 0, 0, 0]],
    tall: [[0.45, -1.55, 0.6, 0.62, 0.06, -0.2, 0], [1.35, -0.55, 0, 0.6, 0, 0, 0], [0.9, -0.55, 0, 0.62, 0.1, 0, 0], [0.9, -2.2, 1.2, 0.36, 0.1, -0.5, 0], [2.2, -0.95, 0, 0.42, 0, 0, 0], [1.6, -0.5, 0, 0.66, 0.22, -0.9, 1], [0, -0.45, 0.3, 0.52, 0, 0, 0]],
  };
  function spring(value, velocity, want, k, d, dt) { velocity += (want - value) * k * dt - velocity * d * dt; return [value + velocity * dt, velocity]; }
  function springVec(value, velocity, want, k, d, dt) {
    for (const c of ['x', 'y', 'z']) { velocity[c] += (want[c] - value[c]) * k * dt - velocity[c] * d * dt; value[c] += velocity[c] * dt; }
  }

  function resize() {
    renderer.setSize(innerWidth, innerHeight, false);
    camera.aspect = innerWidth / innerHeight; camera.updateProjectionMatrix();
    composer.setPixelRatio(Math.min(pixelRatio, lowPower ? 1.1 : 1.5)); composer.setSize(innerWidth, innerHeight);
    film.uniforms.uAspect.value = camera.aspect;
    type.place(reduced ? stillAt : shotAt, camera.aspect, narrow());
    measure(); readScroll();
  }
  addEventListener('resize', resize);
  addEventListener('scroll', readScroll, { passive: true });
  document.addEventListener('visibilitychange', () => { running = !document.hidden; if (running) { last = performance.now(); requestAnimationFrame(frame); } });

  function frame(now) {
    if (!running) return;
    const dt = Math.min(0.05, (now - last) / 1000); last = now;
    if (playing) {
      const end = document.documentElement.scrollHeight - innerHeight;
      const k = clamp((now - playing.at) / 58000, 0, 1);
      scrollTo(0, lerp(playing.from, end, k * k * (3 - 2 * k)));
      if (k >= 1) stopFilm();
    }
    simulate(dt);
    composer.render(dt);
    adapt(dt);
    if (!capture) requestAnimationFrame(frame);
  }

  function simulate(dt) {
    clock += dt;
    const intro = reduced ? 1 : clamp(clock / 2.6, 0, 1);
    const layout = narrow() ? poses.tall : poses.wide;
    // A steadicam: the timeline follows the scroll with a little weight.
    T = reduced ? target : lerp(T, target, 1 - Math.exp(-dt * 3.2));
    const u = T - clamp(Math.floor(T), 0, 6);

    const dy = scrollY - lastScroll; lastScroll = scrollY;
    scrollVel = lerp(scrollVel, dy / Math.max(dt, 1e-3), 0.12);
    const stretch = reduced ? 0 : clamp(Math.abs(scrollVel) / 2600, 0, 1.6);

    // camera
    let shot;
    if (reduced) { const s = STILLS[act]; wantP.set(...s.p); wantL.set(...s.l); shot = { fov: s.fov, bars: 0, roll: 0 }; }
    else shot = shotAt(T, wantP, wantL);
    pointerSmooth.lerp(pointer, 1 - Math.exp(-dt * 3));
    const sway = reduced ? 0 : 1;
    tmp.set(Math.sin(clock * 0.37) * 0.05 + Math.sin(clock * 0.91) * 0.02, Math.sin(clock * 0.53) * 0.04, 0).multiplyScalar(sway);
    camPos.copy(wantP).add(tmp);
    camPos.x += pointerSmooth.x * 0.3 * sway; camPos.y += pointerSmooth.y * 0.18 * sway;
    camLook.copy(wantL);
    camera.position.copy(camPos);
    camera.up.set(Math.sin(shot.roll * 0.2 + Math.sin(clock * 0.3) * 0.004 * sway), 1, 0).normalize();
    camera.lookAt(camLook);
    fov = lerp(fov, shot.fov + (narrow() ? 14 : 0), 1 - Math.exp(-dt * 6));
    camera.fov = fov; camera.updateProjectionMatrix(); camera.updateMatrixWorld();
    speed = lerp(speed, camPos.distanceTo(lastCam) / Math.max(dt, 1e-3), 0.2); lastCam.copy(camPos);
    const inFilm = root.classList.contains('film');
    bars = lerp(bars, reduced ? 0 : Math.max(shot.bars, inFilm ? 1 : 0), 1 - Math.exp(-dt * 4));

    // icon pose
    const pose = layout[act];
    tmp.set(pose[0], pose[1], pose[2]);
    springVec(iconState.p, iconState.v, tmp, 8, 5.2, dt);
    [iconState.s, iconState.sv] = spring(iconState.s, iconState.sv, pose[3], 9, 5.5, dt);
    const lean = act === 0 || act === 6 ? 1 : 0.35;
    [iconState.rx, iconState.rxv] = spring(iconState.rx, iconState.rxv, pose[4] - pointerSmooth.y * 0.22 * lean, 10, 5, dt);
    [iconState.ry, iconState.ryv] = spring(iconState.ry, iconState.ryv, pose[5] + pointerSmooth.x * 0.3 * lean, 10, 5, dt);
    const explodeTarget = pose[6] * (act === 5 ? smooth(0.05, 0.3, u) : 1);
    [iconState.ex, iconState.exv] = spring(iconState.ex, iconState.exv, explodeTarget, 11, 6, dt);
    icon.update(clock, dt, iconState, intro);

    glow.position.set(iconState.p.x, iconState.p.y, iconState.p.z - 1.2);
    glow.scale.setScalar(4.2 * iconState.s);
    glow.quaternion.copy(camera.quaternion);
    const raysOn = act === 0 || act === 6 ? 1 : act === 5 ? 0.45 : 0;
    rays.material.uniforms.uStrength.value = lerp(rays.material.uniforms.uStrength.value, raysOn * intro, 1 - Math.exp(-dt * 2));
    rays.material.uniforms.uTime.value = clock;
    rays.position.copy(iconState.p).add(tmp.set(0, 0, -1.6));
    rays.quaternion.copy(camera.quaternion); rays.scale.setScalar(13 * Math.max(0.6, iconState.s));
    icon.lensWorld(flare.position); flare.position.y += 0.18 * iconState.s; flare.position.z += 0.25;
    flare.quaternion.copy(camera.quaternion);
    flare.material.uniforms.uStrength.value = lerp(flare.material.uniforms.uStrength.value, (act === 0 || act === 6 ? 1 : 0.25) * intro, 1 - Math.exp(-dt * 3));
    stars.rotation.y += dt * 0.004;

    rings.position.copy(iconState.p);
    rings.material.opacity = lerp(rings.material.opacity, act === 2 ? 0.42 : 0, dt * 3);
    rings.visible = rings.material.opacity > 0.01; rings.rotation.z += dt * 0.02;
    bubble.position.copy(iconState.p);
    bubble.userData.s = lerp(bubble.userData.s || 0, act === 4 ? 1 : 0, dt * 3);
    bubble.scale.setScalar(Math.max(0.001, bubble.userData.s) * (narrow() ? 0.78 : 1) * (1 + Math.sin(clock * 1.3) * 0.01));
    bubble.visible = bubble.userData.s > 0.01;
    bubble.material.uniforms.uTime.value = clock;
    wave.visible = act === 3;
    wave.position.set(narrow() ? 0 : -1.55, narrow() ? -0.9 : -0.35, 1.3);
    wave.scale.set(0.5, 0.44, 1);

    // lens projection for the reveal mask
    icon.group.updateMatrixWorld(true);
    icon.lensWorld(tmp);
    const lensDepth = -tmp.clone().applyMatrix4(camera.matrixWorldInverse).z;
    tmp.project(camera);
    const edge = icon.lensEdge(tmp2).project(camera);
    const lensRadius = Math.hypot((edge.x - tmp.x) * camera.aspect, edge.y - tmp.y);
    swarm.update({
      dt, clock, act, u, intro, stretch, icon: iconState.p, lens: tmp, lensRadius, lensDepth, focus: camPos.distanceTo(camLook),
      cursor: pointerSeen && !coarse ? pointerNdc : new Vector2(9, 9), aspect: camera.aspect, narrow: narrow(),
      vortex: pointerSeen && !coarse && !reduced && act === 0 ? cursorOnPlane(camera, pointerNdc, -2.2, vortexPoint) : null,
    });
    type.update(T, clock, reduced, intro);

    // film grade
    flash = Math.max(0, flash - dt * 1.4);
    const f = film.uniforms;
    f.uTime.value = clock; f.uBars.value = bars; f.uFlash.value = flash;
    f.uAberration.value = reduced ? 0 : clamp(speed * 0.00016 + stretch * 0.0025, 0, 0.006);
    f.uGrain.value = reduced ? 0.012 : 0.034;
    bloom.strength = (lowPower ? 0.45 : 0.62) + (act === 6 ? 0.08 : 0);

    // labels
    const w = innerWidth, h = innerHeight;
    if (act === 1) { icon.lensWorld(gateTop.world).y += 0.95 * iconState.s; icon.lensWorld(gateBottom.world).y -= 0.95 * iconState.s; }
    if (act === 2) ringTags.forEach((t, i) => rings.userData.anchor(i, t.world));
    if (act === 5) layerTags.forEach((t, i) => icon.layerAnchor(i, t.world));
    for (const l of labels) {
      const want = l.act === act && !inFilm ? (act === 5 ? smooth(0.18, 0.35, u) : act === 1 ? smooth(0.45, 0.6, u) * (1 - smooth(0.85, 0.95, u)) : 1) : 0;
      l.visible = lerp(l.visible, want, dt * 5);
      tmp.copy(l.world).project(camera);
      if (l.visible < 0.02 || tmp.z > 1) { l.el.style.opacity = '0'; continue; }
      l.el.style.opacity = l.visible.toFixed(3);
      l.el.style.transform = `translate(${((tmp.x + 1) / 2 * w).toFixed(1)}px,${((1 - tmp.y) / 2 * h).toFixed(1)}px)`;
    }
  }
  function adapt(dt) {
    if (clock < 3 || degraded >= 3) return;
    frames++; frameTime += dt;
    if (frames < 90) return;
    const slow = frameTime / frames > 0.024;
    frames = 0; frameTime = 0;
    if (!slow) return;
    degraded++;
    if (degraded === 1) { pixelRatio = Math.max(1, pixelRatio * 0.75); renderer.setPixelRatio(pixelRatio); resize(); }
    else if (degraded === 2) swarm.thin();
    else bloom.enabled = false;
  }

  resize();
  if (location.hostname === 'localhost') { // local preview only: ?act=3&u=0.6 jumps into the film
    const q = new URLSearchParams(location.search), jump = sections.find(x => x.dataset.act === q.get('act'));
    setTimeout(() => {
      if (jump) { sections.forEach(x => { if (x !== jump) x.style.display = 'none'; }); measure(); readScroll(); }
      const uu = parseFloat(q.get('u')), t = parseFloat(q.get('t'));
      for (let i = 0; t > 0 && i < t * 60; i++) simulate(1 / 60);
      if (jump && uu >= 0) { pinned = true; target = +jump.dataset.act + uu; T = target; for (let i = 0; i < 120; i++) simulate(1 / 60); }
    }, 80);
    window.__emblem = { get T() { return T; }, get act() { return act; }, get clock() { return clock; }, step(dt) { readScroll(); simulate(dt); composer.render(dt); } };
  }
  sections.forEach(s => s.classList.toggle('is-active', +s.dataset.act === act));
  root.classList.add('webgl');
  if (!reduced) root.classList.add('intro-on');
  setTimeout(() => root.classList.remove('intro-on'), reduced ? 0 : 1500);
  requestAnimationFrame(frame);
  return true;
}

function cursorOnPlane(camera, ndc, z, out) {
  out.set(ndc.x, ndc.y, 0.5).unproject(camera).sub(camera.position).normalize();
  const t = (z - camera.position.z) / out.z;
  return out.multiplyScalar(t).add(camera.position);
}

// ------------------------------------------------------------------ grade
function filmShader() {
  return {
    uniforms: { tDiffuse: { value: null }, uTime: { value: 0 }, uGrain: { value: 0.034 }, uAberration: { value: 0 }, uBars: { value: 0 }, uFlash: { value: 0 }, uAspect: { value: 1.6 } },
    vertexShader: 'varying vec2 vUv;void main(){vUv=uv;gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.0);}',
    fragmentShader: `
      uniform sampler2D tDiffuse; uniform float uTime, uGrain, uAberration, uBars, uFlash, uAspect; varying vec2 vUv;
      float hash(vec2 p){ return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
      void main(){
        vec2 c = vUv - 0.5; float r2 = dot(c, c);
        vec2 shift = c * uAberration * (0.5 + r2 * 4.0);
        vec3 col = vec3(texture2D(tDiffuse, vUv + shift).r, texture2D(tDiffuse, vUv).g, texture2D(tDiffuse, vUv - shift).b);
        col *= mix(1.0, smoothstep(0.98, 0.3, sqrt(r2) * 1.3), 0.55);
        col += (hash(floor(vUv * vec2(1600.0, 1000.0)) + fract(uTime * 7.3)) - 0.5) * uGrain;
        col = mix(col, vec3(1.0, 0.99, 0.95), uFlash);
        float bar = uBars * min(0.11, max(0.0, (1.0 - uAspect / 2.39) * 0.5));
        col *= step(bar, vUv.y) * step(vUv.y, 1.0 - bar);
        gl_FragColor = vec4(col, 1.0);
      }`,
  };
}

// ------------------------------------------------------------------ studio
function studio() {
  const s = new Scene();
  s.add(new Mesh(new BoxGeometry(12, 12, 12), new MeshBasicMaterial({ color: '#15170f', side: BackSide })));
  const panel = (color, w, h, pos, rot) => {
    const m = new Mesh(new PlaneGeometry(w, h), new MeshBasicMaterial({ color, side: BackSide }));
    m.position.set(...pos); m.rotation.set(...rot); s.add(m);
  };
  panel(new Color(7, 6.8, 6.2), 5, 1.6, [-1.5, 5.8, 1.5], [Math.PI / 2, 0, 0]);
  panel(new Color(2.4, 2.8, 1.8), 1.6, 5, [5.8, 0, -0.5], [0, -Math.PI / 2, 0]);
  panel(new Color(1.4, 1.35, 1.2), 1.6, 5, [-5.8, 0.5, 0.5], [0, Math.PI / 2, 0]);
  panel(new Color(0.9, 1.0, 0.7), 8, 2, [0, -5.8, 0], [-Math.PI / 2, 0, 0]);
  return s;
}

function backGlow() {
  const material = new ShaderMaterial({
    transparent: true, depthWrite: false, ...ADD, toneMapped: false,
    vertexShader: 'varying vec2 vUv;void main(){vUv=uv;gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.0);}',
    fragmentShader: `varying vec2 vUv; void main(){ float d = length(vUv - 0.5) * 2.0; float g = exp(-d * d * 3.2) * 0.22 + exp(-d * d * 14.0) * 0.18;
      gl_FragColor = vec4(vec3(0.33, 0.36, 0.24) * g, 1.0); }`,
  });
  return new Mesh(new PlaneGeometry(1, 1), material);
}

// Cathedral light behind the icon: slow, soft streaks that bloom.
function buildRays() {
  const material = new ShaderMaterial({
    transparent: true, depthWrite: false, ...ADD, toneMapped: false,
    uniforms: { uTime: { value: 0 }, uStrength: { value: 0 } },
    vertexShader: 'varying vec2 vUv;void main(){vUv=uv;gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.0);}',
    fragmentShader: `uniform float uTime, uStrength; varying vec2 vUv;
      void main(){ vec2 p = vUv - 0.5; float r = length(p) * 2.0, a = atan(p.y, p.x);
        float s = pow(abs(sin(a * 7.0 + uTime * 0.07 + sin(a * 19.0 - uTime * 0.11) * 0.7)), 10.0) + pow(abs(sin(a * 13.0 - uTime * 0.05)), 26.0) * 0.6;
        float fall = exp(-r * 2.4) * smoothstep(0.02, 0.18, r) * smoothstep(1.0, 0.62, r);
        gl_FragColor = vec4(vec3(0.62, 0.68, 0.44) * s * fall * uStrength * 0.8, 1.0); }`,
  });
  return new Mesh(new PlaneGeometry(1, 1), material);
}

// An anamorphic streak across the glass highlight.
function buildFlare() {
  const material = new ShaderMaterial({
    transparent: true, depthWrite: false, depthTest: false, ...ADD, toneMapped: false,
    uniforms: { uStrength: { value: 0 } },
    vertexShader: 'varying vec2 vUv;void main(){vUv=uv;gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.0);}',
    fragmentShader: `uniform float uStrength; varying vec2 vUv;
      void main(){ vec2 p = vUv - 0.5; float line = exp(-abs(p.y) * 160.0) * exp(-abs(p.x) * 5.0); vec2 q = p * vec2(1.0, 6.0); float core = exp(-dot(q, q) * 900.0);
        gl_FragColor = vec4((vec3(0.55, 0.7, 0.85) * line * 1.6 + vec3(1.0, 0.98, 0.9) * core * 2.5) * uStrength, 1.0); }`,
  });
  const flare = new Mesh(new PlaneGeometry(7, 0.6), material);
  flare.renderOrder = 10;
  return flare;
}

function buildStars(count) {
  const rnd = random(99), positions = new Float32Array(count * 3), size = new Float32Array(count);
  for (let i = 0; i < count; i++) {
    const u = rnd() * 2 - 1, a = rnd() * TAU, r = 40 + rnd() * 30, s = Math.sqrt(1 - u * u);
    positions.set([Math.cos(a) * s * r, u * r, Math.sin(a) * s * r], i * 3); size[i] = 0.6 + rnd() * 1.8;
  }
  const g = new BufferGeometry(); g.setAttribute('position', new Float32BufferAttribute(positions, 3)); g.setAttribute('size', new Float32BufferAttribute(size, 1));
  const material = new ShaderMaterial({
    transparent: true, depthWrite: false, ...ADD, toneMapped: false,
    vertexShader: 'attribute float size; varying float vA; void main(){ vec4 mv = modelViewMatrix * vec4(position, 1.0); gl_PointSize = size * 2.2; vA = size / 2.4; gl_Position = projectionMatrix * mv; }',
    fragmentShader: 'varying float vA; void main(){ float d = length(gl_PointCoord - 0.5); gl_FragColor = vec4(vec3(0.85, 0.88, 0.75) * smoothstep(0.5, 0.0, d) * vA * 0.7, 1.0); }',
  });
  return new Points(g, material);
}

// ------------------------------------------------------------------ icon
// Built from the four vectors of Resources/AppIcon.icon, in the same order:
// head in front of the glass lens, the body seen through it, the well behind.
function buildIcon() {
  const unit = 2.4 / 1024;
  const group = new Group();
  const pivot = new Group(); group.add(pivot);
  const slabShape = squircle(512, 4.8, 180);
  const glyphScale = 1.28; // Resources/AppIcon.icon: lens radius 358.4 = 280 x 1.28
  const hole = new Path(); hole.absarc(0, 0, 280 * glyphScale, 0, TAU, true); slabShape.holes.push(hole);
  const slabGeometry = new ExtrudeGeometry(slabShape, { depth: 70, bevelEnabled: true, bevelThickness: 22, bevelSize: 18, bevelSegments: 8, curveSegments: 128 });
  slabGeometry.translate(0, 0, -92);
  const sage = new MeshPhysicalMaterial({ color: '#8c9370', roughness: 0.46, clearcoat: 0.75, clearcoatRoughness: 0.22, sheen: 0.5, sheenColor: '#d3d8b4', sheenRoughness: 0.6 });
  const slab = new Mesh(slabGeometry, sage);
  const well = new Mesh(new CircleGeometry(290, 128), new MeshPhysicalMaterial({ color: '#c5c8b2', roughness: 0.85 }));
  well.position.z = -64;
  const bodyShape = new Shape();
  bodyShape.moveTo(-220, -173.205);
  bodyShape.bezierCurveTo(-168, -109, -91, -76, 0, -76);
  bodyShape.bezierCurveTo(91, -76, 168, -109, 220, -173.205);
  bodyShape.absarc(0, 0, 280, -Math.atan2(173.205, 220), -Math.PI + Math.atan2(173.205, 220), true);
  const bodyGeometry = new ExtrudeGeometry(bodyShape, { depth: 12, bevelEnabled: true, bevelThickness: 6, bevelSize: 5, bevelSegments: 4, curveSegments: 96 });
  const white = new MeshPhysicalMaterial({ color: '#ffffff', roughness: 0.3, clearcoat: 0.6, clearcoatRoughness: 0.18 });
  const body = new Mesh(bodyGeometry, white); body.position.z = -56;
  const lensProfile = [];
  for (let i = 0; i <= 40; i++) { const r = 276 * i / 40; lensProfile.push(new Vector2(r, 18 - (r * r) / (276 * 276) * 30)); }
  lensProfile.push(new Vector2(276, -34), new Vector2(0, -34));
  const lensGeometry = new LatheGeometry(lensProfile.reverse(), 128);
  lensGeometry.rotateX(Math.PI / 2);
  const lens = new Mesh(lensGeometry, new MeshPhysicalMaterial({
    color: '#ffffff', transmission: 1, thickness: 0.45, ior: 1.42, roughness: 0.05,
    attenuationColor: '#b8b8a2', attenuationDistance: 1.6, specularIntensity: 0.35, envMapIntensity: 0.7,
  }));
  lens.position.z = -6;
  const head = new Mesh(new SphereGeometry(88, 64, 32), white); head.scale.z = 0.42; head.position.set(0, 68, 34);
  const badgeCanvas = document.createElement('canvas'); badgeCanvas.width = badgeCanvas.height = 512;
  const badgeTexture = new CanvasTexture(badgeCanvas); badgeTexture.colorSpace = SRGBColorSpace;
  const badge = new Mesh(new CircleGeometry(262, 96), new MeshBasicMaterial({ map: badgeTexture, transparent: true, toneMapped: false, depthWrite: false }));
  badge.position.z = 76; badge.visible = false;
  const layers = [head, lens, body, well, slab];
  const baseZ = layers.map(m => m.position.z);
  const explodeZ = [430, 230, 20, -210, -420];
  const glyph = new Group(); glyph.scale.set(glyphScale, glyphScale, 1);
  glyph.add(well, body, lens, head, badge);
  pivot.add(slab, glyph);
  pivot.scale.setScalar(unit);
  const rnd = random(11);
  const from = layers.map(() => new Vector3((rnd() - 0.5) * 9000, (rnd() - 0.5) * 6000, 2500 + rnd() * 5000));
  let spinT = -9, badgeScale = 0, badgeVel = 0, badgeTarget = 0;
  const euler = new Euler();
  return {
    group,
    update(t, dt, state, intro) {
      group.position.copy(state.p);
      group.scale.setScalar(state.s);
      const spin = spinT > 0 ? easeOut((t - spinT) / 1.1) * TAU : 0;
      euler.set(state.rx + Math.sin(t * 0.7) * 0.02, state.ry + spin + Math.sin(t * 0.5) * 0.03, 0);
      group.rotation.copy(euler);
      pivot.position.y = Math.sin(t * 1.1) * 0.03;
      layers.forEach((m, i) => {
        const k = easeOut(clamp((intro - 0.25 - i * 0.07) / 0.45, 0, 1));
        const z = baseZ[i] + explodeZ[i] * state.ex;
        m.position.set(lerp(from[i].x, 0, k), lerp(from[i].y, i === 0 ? 68 : 0, k), lerp(from[i].z, z, k));
        m.rotation.z = (1 - k) * (i % 2 ? 2 : -2);
      });
      badgeVel += (badgeTarget - badgeScale) * 180 * dt - badgeVel * 14 * dt; badgeScale += badgeVel * dt;
      badge.scale.setScalar(Math.max(0.0001, badgeScale));
      badge.visible = badgeScale > 0.01;
      badge.position.z = layers[0].position.z + 42;
    },
    spin(t) { spinT = t; },
    badge(text) {
      if (!text) { badgeTarget = 0; return; }
      drawMonogram(badgeCanvas.getContext('2d'), 0, 0, 512, text, seedOf(text), true);
      badgeTexture.needsUpdate = true; badgeTarget = 1; badgeScale = Math.min(badgeScale, 0.6);
    },
    lensWorld(v) { return v.set(0, 0, 0).applyMatrix4(lens.matrixWorld); },
    lensEdge(v) { group.updateMatrixWorld(); return v.set(276, 0, 0).applyMatrix4(lens.matrixWorld); },
    layerAnchor(i, v) { const m = layers[i]; return v.set(i === 0 ? 120 : i === 4 ? 560 : 330, i === 0 ? 150 : 0, 0).applyMatrix4(m.matrixWorld); },
  };
}

function squircle(half, n, segments) {
  const s = new Shape();
  for (let i = 0; i <= segments; i++) {
    const a = i / segments * TAU, c = Math.cos(a), sn = Math.sin(a);
    const x = half * Math.sign(c) * Math.pow(Math.abs(c), 2 / n), y = half * Math.sign(sn) * Math.pow(Math.abs(sn), 2 / n);
    if (i) s.lineTo(x, y); else s.moveTo(x, y);
  }
  return s;
}

// ------------------------------------------------------------------ atlas
function seedOf(text) { let h = 2166136261; for (const ch of text) { h ^= ch.charCodeAt(0); h = Math.imul(h, 16777619); } return h >>> 0; }
const channel = v => Math.round(clamp(v, 0, 1) * 255);
function drawMonogram(g, x, y, size, text, seed, round) {
  const style = seed % 11 === 10 ? 2 : 0;
  const [r, gg, b] = style === 2 ? SLATE : MONOGRAM[seed % MONOGRAM.length];
  // NameAvatar: value - 0.04 at the bottom, + 0.06 at the top.
  const grad = g.createLinearGradient(0, y + size, 0, y);
  grad.addColorStop(0, `rgb(${channel(r - 0.04)},${channel(gg - 0.04)},${channel(b - 0.04)})`);
  grad.addColorStop(1, `rgb(${channel(r + 0.06)},${channel(gg + 0.06)},${channel(b + 0.06)})`);
  g.save();
  if (round) { g.clearRect(x, y, size, size); g.beginPath(); g.arc(x + size / 2, y + size / 2, size / 2, 0, TAU); g.clip(); }
  g.fillStyle = grad; g.fillRect(x, y, size, size);
  g.fillStyle = '#fff'; g.textAlign = 'center'; g.textBaseline = 'middle';
  const two = text.length > 1;
  g.font = `600 ${Math.round(size * (two ? 0.37 : 0.48))}px ui-rounded, "SF Pro Rounded", "SF Pro Text", system-ui, -apple-system, sans-serif`;
  g.fillText(text, x + size / 2, y + size / 2 + size * 0.03);
  g.restore();
}
function drawMark(g, x, y, size, k) {
  const bg = MARKS[k % MARKS.length];
  const fg = bg === '#ecebe4' || bg === '#ffd23f' ? '#17181a' : '#ffffff';
  g.save(); g.fillStyle = bg; g.fillRect(x, y, size, size);
  g.translate(x + size / 2, y + size / 2); g.fillStyle = fg; g.strokeStyle = fg; g.lineCap = 'round'; g.lineJoin = 'round';
  const u = size / 100;
  switch (Math.floor(k / MARKS.length) % 8) {
    case 0: g.lineWidth = 10 * u; g.beginPath(); g.arc(0, 0, 22 * u, 0, TAU); g.stroke(); break;
    case 1: g.beginPath(); g.moveTo(0, -24 * u); g.lineTo(24 * u, 18 * u); g.lineTo(-24 * u, 18 * u); g.closePath(); g.fill(); break;
    case 2: for (let i = -1; i <= 1; i++) g.fillRect(-22 * u, i * 14 * u - 4 * u, 44 * u - Math.abs(i) * 14 * u, 8 * u); break;
    case 3: for (let i = -1; i <= 1; i++) for (let j = -1; j <= 1; j++) { g.beginPath(); g.arc(i * 15 * u, j * 15 * u, 5 * u, 0, TAU); g.fill(); } break;
    case 4: g.lineWidth = 8 * u; g.beginPath(); for (let i = 0; i <= 24; i++) { const px = -26 * u + i * 52 * u / 24; const py = Math.sin(i / 24 * TAU) * 12 * u; i ? g.lineTo(px, py) : g.moveTo(px, py); } g.stroke(); break;
    case 5: g.beginPath(); for (let i = 0; i < 16; i++) { const a = i / 16 * TAU, rr = i % 2 ? 11 * u : 27 * u; g.lineTo(Math.cos(a) * rr, Math.sin(a) * rr); } g.closePath(); g.fill(); break;
    case 6: g.beginPath(); g.arc(-7 * u, 0, 20 * u, Math.PI / 2, Math.PI * 1.5); g.fill(); g.beginPath(); g.arc(7 * u, 0, 20 * u, -Math.PI / 2, Math.PI / 2); g.fill(); break;
    default: g.lineWidth = 10 * u; g.beginPath(); g.moveTo(-20 * u, -14 * u); g.lineTo(0, 10 * u); g.lineTo(20 * u, -14 * u); g.stroke();
  }
  g.restore();
}
function buildAtlas(renderer) {
  const cells = 16, size = 128;
  const c = document.createElement('canvas'); c.width = c.height = cells * size;
  const g = c.getContext('2d');
  const rnd = random(2026);
  const letters = 'ABCDEFGHIJKLMNOPRSTVWYZ';
  for (let i = 0; i < cells * cells; i++) {
    const x = (i % cells) * size, y = Math.floor(i / cells) * size;
    if (i < 168) {
      const text = letters[Math.floor(rnd() * letters.length)] + (rnd() < 0.62 ? letters[Math.floor(rnd() * letters.length)] : '');
      drawMonogram(g, x, y, size, text, Math.floor(rnd() * 1e9), false);
    } else drawMark(g, x, y, size, i - 168);
  }
  const texture = new CanvasTexture(c);
  texture.colorSpace = SRGBColorSpace; texture.minFilter = LinearMipmapLinearFilter;
  texture.anisotropy = Math.min(8, renderer.capabilities.getMaxAnisotropy());
  return texture;
}

// ------------------------------------------------------------------ type
// Headlines as letters in space. Each glyph has its own atlas cell; the line's
// own measurement keeps the kerning when the letters come back together.
function buildType(renderer, lowPower) {
  const cell = lowPower ? 160 : 256, font = s => `820 ${s}px -apple-system, BlinkMacSystemFont, "SF Pro Display", "Segoe UI", system-ui, sans-serif`;
  const glyphs = new Map();
  for (const t of TYPE) for (const ch of t.line) if (ch !== ' ') glyphs.set(ch + (t.outline ? '~' : ''), 0);
  const cols = 16, rows = Math.ceil(glyphs.size / cols);
  const c = document.createElement('canvas'); c.width = cols * cell; c.height = rows * cell;
  const g = c.getContext('2d');
  const px = cell * 0.72;
  g.font = font(px); g.textBaseline = 'alphabetic'; g.textAlign = 'center';
  let n = 0;
  for (const k of glyphs.keys()) {
    const x = (n % cols) * cell + cell / 2, y = Math.floor(n / cols) * cell + cell * 0.78;
    if (k.endsWith('~')) { g.strokeStyle = '#fff'; g.lineWidth = px * 0.028; g.strokeText(k[0], x, y); }
    else { g.fillStyle = '#fff'; g.fillText(k[0], x, y); }
    glyphs.set(k, n++);
  }
  const texture = new CanvasTexture(c); texture.colorSpace = SRGBColorSpace; texture.minFilter = LinearMipmapLinearFilter;
  texture.anisotropy = Math.min(8, renderer.capabilities.getMaxAnisotropy());
  const material = new ShaderMaterial({
    alphaToCoverage: true,
    uniforms: { uAtlas: { value: texture }, uCols: { value: cols }, uRows: { value: rows }, uNight: { value: new Color(NIGHT) } },
    vertexShader: `attribute float aCell; attribute float aAlpha; uniform float uCols, uRows; varying vec2 vUv; varying float vAlpha, vFog;
      void main(){ vec2 c = vec2(mod(aCell, uCols), floor(aCell / uCols)); vUv = vec2((c.x + uv.x) / uCols, 1.0 - (c.y + 1.0 - uv.y) / uRows);
        vec4 mv = modelViewMatrix * instanceMatrix * vec4(position, 1.0); vAlpha = aAlpha * smoothstep(0.35, 1.4, -mv.z); vFog = smoothstep(14.0, 30.0, -mv.z); gl_Position = projectionMatrix * mv; }`,
    fragmentShader: `uniform sampler2D uAtlas; uniform vec3 uNight; varying vec2 vUv; varying float vAlpha, vFog;
      void main(){ float a = texture2D(uAtlas, vUv).a * vAlpha; if (a < 0.02) discard;
        vec3 col = mix(vec3(0.89, 0.88, 0.81), pow(uNight, vec3(2.2)), vFog); gl_FragColor = vec4(col, a);
        #include <colorspace_fragment>
      }`,
  });
  const group = new Group();
  const lines = TYPE.map((t, index) => {
    const chars = [...t.line];
    g.font = font(px);
    const tracking = -0.065 * px;
    const xs = chars.map((_, i) => g.measureText(t.line.slice(0, i)).width + tracking * i);
    const w = g.measureText(t.line).width + tracking * (chars.length - 1);
    const letters = chars.map((ch, i) => ({ ch, x: xs[i] + g.measureText(ch).width / 2, cell: glyphs.get(ch + (t.outline ? '~' : '')) })).filter(l => l.ch !== ' ');
    const mesh = new InstancedMesh(new PlaneGeometry(1, 1), material, letters.length);
    mesh.frustumCulled = false;
    mesh.geometry.setAttribute('aCell', new InstancedBufferAttribute(new Float32Array(letters.map(l => l.cell)), 1));
    const alpha = new InstancedBufferAttribute(new Float32Array(letters.length), 1); alpha.setUsage(DynamicDrawUsage);
    mesh.geometry.setAttribute('aAlpha', alpha);
    group.add(mesh);
    const rnd = random(31 + index);
    return { t, mesh, alpha, letters, width: w / px, px, frame: new Matrix4(), scale: 1, seeds: letters.map(() => [rnd() - 0.5, rnd() - 0.5, rnd(), rnd() - 0.5]) };
  });
  const m = new Matrix4(), q = new Quaternion(), e = new Euler(), pos = new Vector3(), scl = new Vector3();
  const camP = new Vector3(), camL = new Vector3(), right = new Vector3(), up = new Vector3(), fwd = new Vector3(), back = new Vector3(), origin = new Vector3();
  const worldUp = new Vector3(0, 1, 0);
  return {
    group,
    // Anchor each line where its shot reads it, facing that camera.
    place(shotAt, aspect, narrow) {
      for (const l of lines) {
        const shot = shotAt(l.t.at, camP, camL), fov = (shot.fov + (narrow ? 14 : 0)) * Math.PI / 180;
        // The camera's own frame at that moment (a camera looks down -z).
        fwd.subVectors(camL, camP).normalize(); right.crossVectors(fwd, worldUp).normalize(); up.crossVectors(right, fwd);
        const halfH = Math.tan(fov / 2) * l.t.d, halfW = halfH * aspect;
        const x0 = narrow ? -0.92 : l.t.x, y0 = narrow ? l.t.y + 0.1 : l.t.y;
        l.scale = Math.min(l.t.size * 2 * halfH, (1 - x0) * 0.94 * halfW / Math.max(0.1, l.width));
        origin.copy(camP).addScaledVector(fwd, l.t.d).addScaledVector(right, x0 * halfW).addScaledVector(up, y0 * halfH);
        back.copy(fwd).negate();
        l.frame.makeBasis(right, up, back).setPosition(origin);
      }
    },
    update(T, clock, reduced, intro) {
      for (const l of lines) {
        // With reduced motion the camera holds one shot per act, so each headline holds too.
        const from = reduced ? Math.floor(l.t.at) : l.t.from ?? Math.floor(l.t.at) - 0.02, until = reduced ? Math.floor(l.t.at) + 0.98 : l.t.until ?? Math.floor(l.t.at) + 0.72;
        const visible = (l.t.hero || T > from - 0.2) && T < until + 0.25;
        l.mesh.visible = visible;
        if (!visible) continue;
        const n = l.letters.length;
        l.letters.forEach((letter, i) => {
          const [sx, sy, sz, sr] = l.seeds[i];
          const inT = l.t.hero ? (reduced ? 1 : smooth(0.42 + i * 0.012, 0.66 + i * 0.012, intro)) : reduced ? smooth(from, from + 0.04, T) : smooth(from + i * 0.004, from + 0.08 + i * 0.004, T);
          const outT = reduced ? smooth(until, until + 0.05, T) : smooth(until + (n - i) * 0.004, until + 0.14 + (n - i) * 0.004, T);
          const away = reduced ? 0 : (1 - inT) + outT;
          pos.set(letter.x / l.px * l.scale, 0, 0);
          // Letters arrive out of depth and leave past the camera.
          pos.x += sx * away * 3.5; pos.y += sy * away * 2.4 + Math.sin(clock * 0.8 + i) * 0.01;
          if (!reduced) pos.z += (1 - inT) * (sz * -6 - 2) + outT * (3 + sz * 5);
          e.set(sy * away * 2.2, sx * away * 3, sr * away * 2.5);
          q.setFromEuler(e); scl.setScalar(l.scale / 0.72);
          m.compose(pos, q, scl).premultiply(l.frame);
          l.mesh.setMatrixAt(i, m);
          l.alpha.array[i] = reduced ? inT * (1 - outT) : smooth(0, 0.6, inT) * (1 - smooth(0.4, 1, outT));
        });
        l.mesh.instanceMatrix.needsUpdate = true; l.alpha.needsUpdate = true;
      }
    },
  };
}

// ------------------------------------------------------------------ swarm
function buildSwarm(renderer, count) {
  const plane = new PlaneGeometry(1, 1);
  const geometry = new InstancedBufferGeometry();
  geometry.index = plane.index;
  geometry.setAttribute('position', plane.getAttribute('position'));
  geometry.setAttribute('uv', plane.getAttribute('uv'));
  geometry.instanceCount = count;
  const P = new Float32Array(count * 3), V = new Float32Array(count * 3), T = new Float32Array(count * 3);
  const S = new Float32Array(count), ST = new Float32Array(count), Z = new Float32Array(count), ZT = new Float32Array(count);
  const G = new Float32Array(count), GT = new Float32Array(count), cell = new Float32Array(count);
  const seed = new Float32Array(count), seed2 = new Float32Array(count), seed3 = new Float32Array(count), phase = new Float32Array(count);
  const K = new Float32Array(count), lock = new Float32Array(count), pinged = new Uint8Array(count), prevU = new Float32Array(count);
  const ring = new Uint8Array(count), dive = new Float32Array(count).fill(-99), portrait = new Uint8Array(count);
  const rnd = random(4242);
  const monogramRings = [0, 5, 6], markRings = [1, 2, 3, 4];
  for (let i = 0; i < count; i++) {
    seed[i] = rnd(); seed2[i] = rnd(); seed3[i] = rnd(); phase[i] = rnd();
    const isMark = rnd() < 0.3;
    cell[i] = isMark ? 168 + Math.floor(rnd() * 88) : Math.floor(rnd() * 168);
    ring[i] = isMark ? markRings[Math.floor(rnd() * 4)] : monogramRings[Math.floor(rnd() * 3)];
    K[i] = 3.2 + rnd() * 4.5;
    const a = rnd() * TAU, r = Math.sqrt(rnd()) * 2.25;
    P[i * 3] = Math.cos(a) * r; P[i * 3 + 1] = Math.sin(a) * r; P[i * 3 + 2] = (rnd() - 0.5) * 0.1;
    const x = P[i * 3], y = P[i * 3 + 1];
    const silhouette = Math.hypot(x, y - 0.55) < 0.72 || (Math.hypot(x / 1.35, (y + 1.25) / 0.95) < 1 && y < -0.3);
    G[i] = silhouette ? 0.42 : 0;
    S[i] = 0.12; Z[i] = 1;
    // The finale portrait: a sunflower disc of every face, head and shoulders lit.
    const k = (i + 0.5) / count, pr = Math.sqrt(k), pa = i * 2.39996;
    const px = Math.cos(pa) * pr, py = Math.sin(pa) * pr;
    portrait[i] = Math.hypot(px, py - 0.243) < 0.314 || (Math.hypot(px / 0.62, (py + 0.62) / 0.5) < 1 && py < -0.05) ? 1 : 0;
  }
  const attr = (array, size) => { const a = new InstancedBufferAttribute(array, size); a.setUsage(DynamicDrawUsage); return a; };
  const aPos = attr(P, 3), aScale = attr(S, 1), aState = attr(Z, 1), aGlow = attr(G, 1);
  geometry.setAttribute('aPos', aPos); geometry.setAttribute('aScale', aScale);
  geometry.setAttribute('aState', aState); geometry.setAttribute('aGlow', aGlow);
  geometry.setAttribute('aCell', new InstancedBufferAttribute(cell, 1));
  const uniforms = {
    uAtlas: { value: buildAtlas(renderer) }, uStretch: { value: 0 }, uLens: { value: new Vector2(9, 9) },
    uLensR: { value: 0 }, uLensDepth: { value: 0 }, uCursor: { value: new Vector2(9, 9) }, uCursorR: { value: 0.22 },
    uAspect: { value: 1 }, uNight: { value: new Color(NIGHT) }, uShock: { value: -1 }, uShockAt: { value: new Vector2() },
    uFocus: { value: 8 }, uAperture: { value: 0.35 }, uFogFar: { value: 26 },
  };
  const vertexCommon = `
      attribute vec3 aPos; attribute float aScale; attribute float aState; attribute float aGlow; attribute float aCell;
      uniform float uStretch, uLensR, uLensDepth, uCursorR, uAspect, uShock, uFocus, uAperture, uFogFar; uniform vec2 uLens, uCursor, uShockAt;
      varying vec2 vUv; varying float vCell, vState, vGlow, vFog, vBlur;
      void place(float grow){
        vUv = uv; vCell = aCell; vGlow = aGlow;
        vec4 centre = modelViewMatrix * vec4(aPos, 1.0);
        vec4 clipCentre = projectionMatrix * centre;
        vec2 ndc = clipCentre.xy / clipCentre.w;
        float behind = step(uLensDepth, -centre.z);
        float lens = (1.0 - smoothstep(uLensR * 0.78, uLensR, length((ndc - uLens) * vec2(uAspect, 1.0)))) * behind;
        float cursor = 1.0 - smoothstep(uCursorR * 0.45, uCursorR, length((ndc - uCursor) * vec2(uAspect, 1.0)));
        float shock = uShock >= 0.0 ? 1.0 - smoothstep(0.0, 0.22, abs(length((ndc - uShockAt) * vec2(uAspect, 1.0)) - uShock)) : 0.0;
        vState = max(aState, 2.0 * max(max(lens, cursor), shock));
        vGlow += shock * 0.9 + cursor * 0.18;
        float depth = -centre.z;
        // Close faces fall out of focus into soft, glowing bokeh.
        vBlur = clamp(abs(1.0 / max(depth, 0.05) - 1.0 / uFocus) * uAperture * 6.0 - 0.15, 0.0, 1.0) * step(depth, uFocus);
        vec2 q = position.xy; q.y *= 1.0 + uStretch; q.x *= 1.0 / (1.0 + uStretch * 0.35);
        vec4 mv = centre; mv.xy += q * aScale * (1.0 + shock * 0.35) * (1.0 + vBlur * grow);
        vFog = smoothstep(uFogFar * 0.42, uFogFar, depth);
        gl_Position = projectionMatrix * mv;
      }`;
  const material = new ShaderMaterial({
    alphaToCoverage: true, uniforms,
    vertexShader: vertexCommon + 'void main(){ place(0.0); }',
    fragmentShader: `
      uniform sampler2D uAtlas; uniform vec3 uNight;
      varying vec2 vUv; varying float vCell, vState, vGlow, vFog, vBlur;
      vec3 lin(vec3 c){ return pow(c, vec3(2.2)); }
      float box(vec2 p, vec2 b, float r){ vec2 q = abs(p) - b + r; return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r; }
      float seg(vec2 p, vec2 a, vec2 b){ vec2 pa = p - a, ba = b - a; return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0)); }
      void main(){
        if (vBlur > 0.5) discard;
        vec2 p = vUv - 0.5;
        float envelope = clamp(1.0 - vState, 0.0, 1.0);
        float found = clamp(vState - 1.0, 0.0, 1.0);
        float d = mix(length(p) - 0.46, box(p, vec2(0.47, 0.33), 0.07), envelope);
        float aa = fwidth(d) * 1.1;
        float alpha = 1.0 - smoothstep(-aa, aa, d);
        if (alpha < 0.01) discard;
        vec3 grey = mix(lin(vec3(0.19, 0.20, 0.18)), lin(vec3(0.27, 0.28, 0.25)), vUv.y);
        float head = 1.0 - smoothstep(-0.01, 0.01, length(p - vec2(0.0, 0.1)) - 0.155);
        float shoulders = 1.0 - smoothstep(-0.01, 0.01, length((p - vec2(0.0, -0.4)) * vec2(1.0, 1.3)) - 0.33);
        vec3 placeholder = mix(grey, lin(vec3(0.44, 0.45, 0.41)), max(head, shoulders));
        vec3 paper = mix(lin(vec3(0.58, 0.58, 0.52)), lin(vec3(0.78, 0.77, 0.70)), vUv.y);
        vec2 tip = vec2(0.0, -0.02);
        float flap = min(seg(p, vec2(-0.47, 0.33), tip), seg(p, vec2(0.47, 0.33), tip));
        paper *= mix(1.0, 0.9, step(tip.y + abs(p.x) * 0.745, p.y));
        paper = mix(paper * 0.62, paper, smoothstep(0.006, 0.022, flap));
        paper = mix(paper, lin(vec3(0.49, 0.53, 0.37)), 1.0 - smoothstep(0.06, 0.075, length(p - tip)));
        vec2 c = vec2(mod(vCell, 16.0), floor(vCell / 16.0));
        vec2 uv = vec2((c.x + 0.03 + vUv.x * 0.94) / 16.0, 1.0 - (c.y + 0.97 - vUv.y * 0.94) / 16.0);
        vec3 face = texture2D(uAtlas, uv).rgb;
        vec3 col = mix(placeholder, face, found);
        col = mix(col, paper, envelope);
        col *= 0.9 + 0.1 * smoothstep(0.47, 0.25, length(p));
        col += vGlow * lin(vec3(0.95, 0.97, 0.78)) * 0.9;
        col = mix(col, lin(uNight), vFog);
        gl_FragColor = vec4(col, alpha);
        #include <colorspace_fragment>
      }`,
  });
  const bokehMaterial = new ShaderMaterial({
    transparent: true, depthWrite: false, ...ADD, toneMapped: false, uniforms,
    vertexShader: vertexCommon + 'void main(){ place(2.2); }',
    fragmentShader: `
      uniform sampler2D uAtlas; varying vec2 vUv; varying float vCell, vState, vBlur, vGlow;
      void main(){
        if (vBlur <= 0.5) discard;
        float r = length(vUv - 0.5) * 2.0;
        float disc = smoothstep(1.0, 0.82, r) * (0.55 + 0.45 * smoothstep(0.55, 0.95, r));
        vec2 c = vec2(mod(vCell, 16.0), floor(vCell / 16.0));
        vec3 tint = vState > 1.5 ? texture2D(uAtlas, vec2((c.x + 0.5) / 16.0, 1.0 - (c.y + 0.5) / 16.0), 6.0).rgb : vec3(0.3, 0.32, 0.27);
        float strength = smoothstep(0.5, 0.75, vBlur) * 0.34 / (1.0 + vBlur * 1.6);
        gl_FragColor = vec4(pow(tint, vec3(2.2)) * disc * strength * (1.0 + vGlow * 2.0), 1.0);
      }`,
  });
  const mesh = new Mesh(geometry, material); mesh.frustumCulled = false;
  const bokeh = new Mesh(geometry, bokehMaterial); bokeh.frustumCulled = false; bokeh.renderOrder = 5;
  let shockAt = -9, active = count, lastAct = 0;
  const ringTilt = new Euler(1.12, 0, 0.22), scratch = new Vector3();

  function target(i, s) {
    const { clock: t, act, u, icon, narrow } = s;
    const o = i * 3;
    let x = 0, y = 0, z = 0, scale = 0.1, state = 2, glow = 0, snap = false;
    if (act === 0) {
      const arm = i % 3, r = 1.25 + Math.pow(seed[i], 0.7) * 8.8;
      const a = phase[i] * 0.5 + arm * TAU / 3 + r * 0.5 + t * (0.03 + 0.1 / r);
      const lx = Math.cos(a) * r, ly = Math.sin(a) * r * 0.36 + (seed2[i] - 0.5) * 0.5;
      x = icon.x * 0.6 + lx; y = icon.y * 0.4 + ly * 0.9 - lx * 0.08; z = -2.2 - Math.sin(a) * r * 0.55 + (seed3[i] - 0.5) * 0.9;
      scale = (0.06 + seed2[i] * 0.12) * (narrow ? 0.85 : 1);
      state = pinged[i] ? 2 : 1;
    } else if (act === 1) {
      const w = (phase[i] + t * (0.028 + seed2[i] * 0.012)) % 1;
      if (w < prevU[i]) snap = true;
      prevU[i] = w;
      const zz = lerp(-17, 8.5, w), d = zz - icon.z;
      const radius = d < 0 ? 0.3 + Math.pow(-d / 17, 0.85) * 4.2 : 0.3 + Math.pow(d / 8.5, 1.1) * 2.6;
      const a = seed[i] * TAU + w * TAU * 4.5 + (d > 0 ? d * 0.25 : 0);
      x = icon.x + Math.cos(a) * radius; y = icon.y + Math.sin(a) * radius * 0.82; z = zz;
      scale = 0.15 * smooth(0, 0.05, w) * (1 - smooth(0.62, 0.9, w)) * (d < 0 ? 1.1 : 1);
      state = smooth(-0.35, 0.35, d) * 2;
    } else if (act === 2) {
      const k = ring[i], radius = 1.35 + k * 0.36 + (seed2[i] - 0.5) * 0.06;
      const a = phase[i] * TAU + t * (0.26 - k * 0.022) * (k % 2 ? 1 : -1);
      const local = scratch.set(Math.cos(a) * radius, Math.sin(a) * radius, (seed3[i] - 0.5) * 0.06).applyEuler(ringTilt);
      x = icon.x + local.x; y = icon.y + local.y; z = icon.z + local.z;
      scale = 0.055 + (6 - k) * 0.008 + seed[i] * 0.018;
      const since = t - dive[i];
      if (since >= 0 && since < 1.6) {
        const e = easeOut(since / 1.1), back = smooth(1.15, 1.6, since), spiral = (1 - e) * 1.4;
        x = lerp(x, icon.x + Math.cos(a + spiral) * 0.05, e * (1 - back));
        y = lerp(y, icon.y + Math.sin(a + spiral) * 0.05, e * (1 - back));
        z = lerp(z, icon.z + 0.55, e * (1 - back));
        scale *= 1 + e * (1 - back) * 5.5;
        glow = e * (1 - back) * 0.8;
      }
    } else if (act === 3) {
      const rows = narrow ? 30 : 34, cols = Math.ceil(active / rows), col = i % cols, row = Math.floor(i / cols);
      const radius = narrow ? 1.5 : 2.05, a = col / cols * TAU + t * 0.22, gap = (narrow ? 2.9 : 3.3) / rows;
      const cx = narrow ? 0 : -1.55, cy = narrow ? -0.9 : -0.35;
      x = cx + Math.sin(a) * radius; z = -0.8 + Math.cos(a) * radius; y = cy + (row - (rows - 1) / 2) * gap;
      scale = gap * 0.86;
      if (Math.cos(a) > 0.996 && Math.sin(a) > 0) G[i] = 1;
    } else if (act === 4) {
      const k = i + 0.5, phi = Math.acos(1 - 2 * k / active), theta = Math.PI * (1 + Math.sqrt(5)) * k + t * 0.18;
      const radius = (narrow ? 1.0 : 1.2) + Math.sin(t * 1.4 + i) * 0.02;
      x = icon.x + Math.cos(theta) * Math.sin(phi) * radius; y = icon.y + Math.cos(phi) * radius; z = icon.z + Math.sin(theta) * Math.sin(phi) * radius;
      scale = 0.075;
    } else if (act === 5) {
      const v = seed[i] * 2 - 1, a = seed2[i] * TAU, rr = 7 + seed3[i] * 10, sq = Math.sqrt(1 - v * v);
      x = Math.cos(a) * sq * rr; y = v * rr * 0.7; z = Math.min(-2.5, Math.sin(a) * sq * rr - 6);
      scale = 0.03 + seed[i] * 0.035;
    } else if (u < 0.56) {
      // The finale: every face in the sky, together drawing the Emblem portrait.
      const k = (i + 0.5) / count, pr = Math.sqrt(k) * 9.5, pa = i * 2.39996 + t * 0.012;
      x = Math.cos(pa) * pr; y = 2.4 + Math.sin(pa) * pr; z = -16 + Math.sin(pa * 3 + t) * 0.15;
      scale = 9.5 * Math.sqrt(Math.PI / count) * 1.05;
      glow = portrait[i] ? 0.34 : 0;
    } else {
      const a = phase[i] * TAU + t * (0.22 + seed2[i] * 0.05), radius = (narrow ? 1.35 : 1.75) + (seed[i] - 0.5) * 0.8;
      x = icon.x + Math.cos(a) * radius; y = icon.y + Math.sin(a) * radius * 0.92; z = icon.z - 1.3 + (seed3[i] - 0.5) * 0.9;
      scale = 0.1 + seed2[i] * 0.06;
    }
    T[o] = x; T[o + 1] = y; T[o + 2] = z; ST[i] = scale; ZT[i] = state; GT[i] = glow;
    return snap;
  }

  return {
    mesh, bokeh,
    kick(act) {
      if (reduced) return;
      for (let i = 0; i < active; i++) {
        lock[i] = -seed3[i] * 0.6;
        const o = i * 3, power = 2.5 + seed[i] * 4;
        V[o] += (seed2[i] - 0.5) * power; V[o + 1] += (seed3[i] - 0.5) * power; V[o + 2] += (seed[i] - 0.3) * power;
      }
      if (act === 1) prevU.fill(0);
    },
    shock(t, at) { shockAt = t; uniforms.uShockAt.value.copy(at); for (let i = 0; i < active; i++) pinged[i] = 1; },
    thin() { active = Math.floor(active * 0.55); geometry.instanceCount = active; },
    update(s) {
      const { dt, clock: t, act, intro } = s;
      uniforms.uStretch.value = s.stretch; uniforms.uLens.value.set(s.lens.x, s.lens.y);
      uniforms.uLensR.value = act === 0 || act === 6 ? s.lensRadius : act === 1 ? s.lensRadius * 0.9 : 0;
      uniforms.uLensDepth.value = s.lensDepth; uniforms.uCursor.value.copy(s.cursor); uniforms.uAspect.value = s.aspect;
      const shockAge = t - shockAt;
      uniforms.uShock.value = shockAge < 1.4 ? easeOut(shockAge / 1.4) * 3.2 : -1;
      uniforms.uFocus.value = lerp(uniforms.uFocus.value, reduced ? 50 : Math.max(0.6, s.focus), 1 - Math.exp(-dt * 4));
      uniforms.uFogFar.value = lerp(uniforms.uFogFar.value, act === 6 ? 70 : 26, 1 - Math.exp(-dt * 3));
      uniforms.uAperture.value = reduced ? 0 : 0.35;
      const reveal = reduced ? 0.6 : clamp((t - 2.4) / 9, 0, 0.35) + clamp((t - 11) / 30, 0, 0.4);
      if (act === 2 && !reduced && Math.floor(t * 2.2) !== Math.floor((t - dt) * 2.2)) {
        const pick = Math.floor(Math.random() * active); if (ring[pick] >= 3) dive[pick] = t;
      }
      const introHold = intro < 0.34, changed = act !== lastAct; lastAct = act;
      for (let i = 0; i < active; i++) {
        const o = i * 3;
        if (!pinged[i] && seed3[i] < reveal) { pinged[i] = 1; G[i] = 1; }
        if (introHold) { ST[i] = 0.12; continue; }
        const snap = target(i, s);
        if (snap || (reduced && changed)) { P[o] = T[o]; P[o + 1] = T[o + 1]; P[o + 2] = T[o + 2]; V[o] = V[o + 1] = V[o + 2] = 0; S[i] = 0; }
        if (s.vortex) {
          const dx = P[o] - s.vortex.x, dy = P[o + 1] - s.vortex.y, r2 = dx * dx + dy * dy;
          if (r2 < 2.6) { const f = (1 - Math.sqrt(r2) / 1.61) ** 2 * 26; V[o] += (-dy * 1.6 - dx * 0.5) * f * dt; V[o + 1] += (dx * 1.6 - dy * 0.5) * f * dt; if (f > 6 && !pinged[i]) { pinged[i] = 1; G[i] = 1; } }
        }
        lock[i] = Math.min(1, lock[i] + dt * 0.7);
        const k = reduced ? 40 : lerp(K[i], 38, clamp(lock[i], 0, 1) ** 2);
        const d = reduced ? 12.6 : 2 * Math.sqrt(k) * (0.62 + 0.25 * clamp(lock[i], 0, 1));
        for (let j = 0; j < 3; j++) { V[o + j] += ((T[o + j] - P[o + j]) * k - V[o + j] * d) * dt; P[o + j] += V[o + j] * dt; }
        S[i] = lerp(S[i], ST[i], 1 - Math.exp(-dt * 6));
        Z[i] = lerp(Z[i], ZT[i], 1 - Math.exp(-dt * (act === 1 ? 14 : 3)));
        G[i] = Math.max(GT[i], G[i] - dt * 1.6);
      }
      if (introHold) for (let i = 0; i < active; i++) G[i] = G[i] > 0.3 ? 0.42 : 0;
      aPos.needsUpdate = aScale.needsUpdate = aState.needsUpdate = aGlow.needsUpdate = true;
    },
  };
}

// ------------------------------------------------------------------ props
function buildRings() {
  const points = [], tilt = new Euler(1.12, 0, 0.22), v = new Vector3();
  for (let k = 0; k < 7; k++) {
    const r = 1.35 + k * 0.36;
    for (let i = 0; i < 160; i++) {
      for (const a of [i / 160 * TAU, (i + 1) / 160 * TAU]) { v.set(Math.cos(a) * r, Math.sin(a) * r, 0).applyEuler(tilt); points.push(v.x, v.y, v.z); }
    }
  }
  const g = new BufferGeometry(); g.setAttribute('position', new Float32BufferAttribute(points, 3));
  const rings = new LineSegments(g, new LineBasicMaterial({ color: '#c8d19a', transparent: true, opacity: 0, depthWrite: false }));
  rings.userData.anchor = (k, out) => {
    const r = 1.35 + k * 0.36, a = -0.35 - k * 0.36;
    return out.set(Math.cos(a) * r, Math.sin(a) * r, 0).applyEuler(tilt).applyEuler(rings.rotation).add(rings.position);
  };
  return rings;
}

function buildBubble() {
  const material = new ShaderMaterial({
    transparent: true, depthWrite: false, ...ADD, toneMapped: false, side: DoubleSide,
    uniforms: { uTime: { value: 0 } },
    vertexShader: `varying vec3 vN; varying vec3 vV; varying vec3 vP;
      void main(){ vec4 w = modelMatrix * vec4(position, 1.0); vP = position; vN = normalize(mat3(modelMatrix) * normal); vV = normalize(cameraPosition - w.xyz); gl_Position = projectionMatrix * viewMatrix * w; }`,
    fragmentShader: `uniform float uTime; varying vec3 vN; varying vec3 vV; varying vec3 vP;
      void main(){ float f = pow(1.0 - abs(dot(normalize(vN), normalize(vV))), 3.0);
        float band = 0.5 + 0.5 * sin(vP.y * 9.0 - uTime * 1.4);
        vec3 c = mix(vec3(0.55, 0.62, 0.40), vec3(0.95, 0.97, 0.85), f) * (f * 1.1 + band * f * 0.35);
        float hi = pow(max(0.0, dot(normalize(vN), normalize(vec3(-0.5, 0.7, 0.6)))), 60.0) * 1.4;
        gl_FragColor = vec4(c * 1.2 + hi, 1.0); }`,
  });
  const bubble = new Mesh(new SphereGeometry(1.7, 96, 64), material);
  bubble.visible = false; bubble.userData.s = 0;
  return bubble;
}

function buildWave() {
  const material = new ShaderMaterial({
    transparent: true, depthWrite: false, ...ADD, toneMapped: false,
    vertexShader: 'varying vec2 vUv;void main(){vUv=uv;gl_Position=projectionMatrix*modelViewMatrix*vec4(position,1.0);}',
    fragmentShader: `varying vec2 vUv; void main(){ float x = abs(vUv.x - 0.5) * 2.0; float g = exp(-x * x * 18.0) * smoothstep(0.0, 0.2, vUv.y) * smoothstep(1.0, 0.8, vUv.y);
      gl_FragColor = vec4(vec3(0.85, 0.92, 0.62) * g * 0.9, 1.0); }`,
  });
  const wave = new Mesh(new PlaneGeometry(0.9, 9), material);
  wave.visible = false;
  return wave;
}

if ('scrollRestoration' in history) history.scrollRestoration = 'manual';
if (!start()) root.classList.add('no-webgl');
