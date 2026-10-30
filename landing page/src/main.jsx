import React, { useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { gsap } from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import './styles.css';

const BASE = import.meta.env.BASE_URL;
const REPO = 'https://github.com/abrar225/Framecast-Studio';

function Mark({ className = '' }) {
  return <svg className={className} viewBox="0 0 34 34" fill="none" aria-hidden="true">
    <rect x="2" y="2" width="30" height="30" rx="9" fill="currentColor" />
    <path d="M9 11h16v11H9zM13 26h8m-4-4v4m-4-11h6m-6 3h3" stroke="#141714" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
    <circle cx="22" cy="17" r="1.8" fill="#141714" />
  </svg>;
}

function Arrow({ diagonal = false }) {
  return <svg className="arrow-icon" viewBox="0 0 20 20" fill="none" aria-hidden="true">
    {diagonal ? <path d="M5 15 15 5M6 5h9v9" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" /> : <path d="M3 10h13m-5-5 5 5-5 5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />}
  </svg>;
}

function Header() {
  const [open, setOpen] = useState(false);
  return <header className="site-header">
    <a className="brand" href="#top" aria-label="Framecast Studio home"><Mark /><span>Framecast<span className="brand-studio">Studio</span></span></a>
    <button className="menu-button" aria-expanded={open} aria-label={open ? 'Close menu' : 'Open menu'} onClick={() => setOpen(!open)}><i /><i /></button>
    <nav className={open ? 'nav-links open' : 'nav-links'} aria-label="Main navigation">
      <a href="#studio" onClick={() => setOpen(false)}>The studio</a>
      <a href="#details" onClick={() => setOpen(false)}>What it does</a>
      <a href="#roadmap" onClick={() => setOpen(false)}>Project status</a>
      <a className="nav-github" href={REPO} target="_blank" rel="noreferrer">Source <Arrow diagonal /></a>
    </nav>
  </header>;
}

function LottieSignal() {
  const ref = useRef(null);
  useEffect(() => {
    const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    let disposed = false;
    let animation;
    import('lottie-web/build/player/lottie_svg.js').then(({ default: lottie }) => {
      if (disposed) return;
      animation = lottie.loadAnimation({
        container: ref.current,
        renderer: 'svg',
        loop: !reduced,
        autoplay: !reduced,
        path: `${BASE}media/signal.json`,
        rendererSettings: { preserveAspectRatio: 'xMidYMid meet' },
      });
    });
    return () => { disposed = true; animation?.destroy(); };
  }, []);
  return <div className="signal-lottie" ref={ref} aria-hidden="true" />;
}

function Hero({ onWatch }) {
  const [mode, setMode] = useState('both');
  const [playing, setPlaying] = useState(false);
  return <section className="hero" id="top">
    <div className="hero-backdrop" aria-hidden="true"><div className="hero-ring" /><div className="hero-gridline" /></div>
    <div className="hero-content">
      <div className="hero-copy">
        <p className="eyebrow hero-eyebrow"><span className="eyebrow-mark" /> Open source studio for Mac</p>
        <h1 className="hero-title">A screen worth<br /><span>staying for.</span></h1>
        <p className="hero-description">Framecast gives your screen, camera, and ideas a place to land. Set the scene, check the sound, and make the take.</p>
        <div className="hero-actions">
          <a className="button button-lime" href={`${REPO}#requirements-and-build`} target="_blank" rel="noreferrer">Build from source <Arrow /></a>
          <button className="button button-watch" onClick={onWatch}><span className="play-triangle" /> Watch the studio</button>
        </div>
        <p className="hero-footnote"><span>MIT licensed</span><b>·</b><span>macOS 14.2+</span><b>·</b><span>Early release</span></p>
      </div>

      <div className="hero-stage" id="studio">
        <div className="stage-caption"><span>Framecast Studio 1.4.2</span><span className="stage-preview">Product preview</span></div>
        <div className={`stage-window mode-${mode}`}>
          <div className="stage-window-top"><span className="window-lights"><i /><i /><i /></span><span>Screen + camera</span><span className="stage-time">00:18:24</span></div>
          <div className="stage-workspace">
            <div className="stage-editor">
              <div className="stage-toolbar"><span>Preview</span><div className="stage-format" role="group" aria-label="Preview format">
                {['wide', 'tall', 'both'].map((value) => <button key={value} onClick={() => { setMode(value); setPlaying(true); }} aria-pressed={mode === value}>{value === 'wide' ? 'Wide' : value === 'tall' ? 'Tall' : 'Both'}</button>)}
              </div></div>
              <div className="stage-canvases">
                <div className="preview-canvas wide-canvas"><div className="preview-browser"><div className="browser-bar"><i /><i /><i /><span>framecast-studio.app</span></div><div className="browser-art"><div className="browser-copy"><small>STUDIO NOTES / 04</small><b>Give your<br />work a frame.</b><span>Screen, camera, sound.<br />All in the same take.</span></div><div className="browser-shape" /><div className="browser-lines"><i /><i /><i /></div></div></div><div className="mini-camera"><span /><b>CAMERA</b></div><label>HORIZONTAL · 16:9</label></div>
                <div className="preview-canvas tall-canvas"><div className="vertical-art"><small>FRAMECAST / 01</small><b>Look<br />closer.</b><div className="portrait-scene"><i /><span /></div><label>VERTICAL · 9:16</label></div></div>
              </div>
              <div className="stage-layouts"><span className="layout-swatch active"><i /><b>Screen + cam</b></span><span className="layout-swatch"><i /><b>Just me</b></span><span className="layout-swatch"><i /><b>Side by side</b></span><span className="layout-swatch"><i /><b>Screen focus</b></span></div>
            </div>
            <aside className="stage-tools"><div className="tool-title">Studio tools</div><div className="tool-active"><span>●</span> Screen capture <b>Ready</b></div><div className="tool-line"><span className="camera-symbol">◉</span><div><b>Camera</b><small>Frame your shot</small></div><i className="toggle-on" /></div><div className="tool-line"><LottieSignal /><div><b>Microphone</b><small>Signal detected</small></div></div><div className="tool-chat"><span>Live chat</span><b>Local overlay</b><small>Keep the useful bits<br />in view.</small></div><div className="tool-status"><i /> Recording locally</div></aside>
          </div>
          <div className="stage-bottom"><span>ScreenCaptureKit</span><span>1920 × 1080</span><span>H.264 · 30 fps</span></div>
        </div>
        <div className="stage-note"><span>Drag the format selector</span><span>Native Mac capture</span></div>
        <div className={`stage-spark ${playing ? 'spark-active' : ''}`} aria-hidden="true"><i /><i /><i /><i /><i /></div>
      </div>
    </div>
    <div className="hero-bottom"><span>Screen recording, composed.</span><a href="#details">Explore the studio <Arrow /></a><span>01 / 04</span></div>
  </section>;
}

function Intro() {
  return <section className="intro section-wrap reveal" id="details">
    <div className="intro-label"><span className="section-index">01</span><span>One app, considered from the first frame</span></div>
    <div className="intro-copy"><h2>Make a clear take<br />of what you <em>do.</em></h2><p>Record a tutorial. Walk through a new idea. Share your workflow while your camera keeps you in the room. Framecast brings the pieces together on your Mac.</p></div>
  </section>;
}

function Workbench() {
  return <section className="workbench section-wrap reveal">
    <div className="workbench-top"><div><p className="eyebrow">The canvas is yours</p><h2>Compose once.<br /><span>Find the frame.</span></h2></div><p className="workbench-blurb">Start with a layout. Move the screen, shift the camera, or bring the desktop forward. The preview keeps both formats visible while you work.</p></div>
    <div className="workbench-visual">
      <div className="workbench-rail"><span>LAYOUTS</span><div className="rail-items"><i className="rail-active"><b /></i><i><b /></i><i><b /></i><i><b /></i><i><b /></i></div><span className="rail-link">Add a layout <Arrow diagonal /></span></div>
      <div className="workbench-preview"><div className="wb-toolbar"><span>Horizontal <small>16:9</small></span><span>Vertical <small>9:16</small></span><b>LINKED</b></div><div className="wb-canvases"><div className="wb-landscape"><div className="wb-desktop"><div className="wb-code"><i /><i /><i /><i /><i /><i /></div></div><div className="wb-face" /></div><div className="wb-portrait"><div className="wb-desktop"><div className="wb-code"><i /><i /><i /><i /></div></div><div className="wb-face" /></div></div><div className="wb-bottom"><span>Screen + camera</span><span>Move · Resize · Fit · Lock</span><span>Undo / Redo</span></div></div>
      <div className="workbench-side"><p>EDIT SCENE</p><strong>Screen source</strong><span>Size · Fit · Position</span><div className="side-slider"><i /></div><span>Keep aspect ratio <b>ON</b></span><hr /><strong>Camera frame</strong><span>Shape · Crop · Position</span><div className="shape-set"><i /><i /><i /></div><div className="side-buttons"><b>Center</b><b>Lock</b></div></div>
    </div>
    <div className="workbench-meta"><span><strong>9</strong> built-in scenes</span><span><strong>2</strong> independent canvases</span><span>Editable down to the pixel</span></div>
  </section>;
}

function UseCases() {
  const cases = [
    { id: 'A', title: 'Teach the workflow', body: 'Keep the important controls legible while you explain what happens on screen.', tone: 'case-citron' },
    { id: 'B', title: 'Make a product walk-through', body: 'Frame a feature, add context, and let the details carry the story.', tone: 'case-lilac' },
    { id: 'C', title: 'Bring your voice along', body: 'Check the microphone and app audio before you save the take.', tone: 'case-peach' },
  ];
  return <section className="use-cases section-wrap reveal">
    <div className="use-heading"><p className="eyebrow">Good for the work in front of you</p><h2>Make the screen<br /><span>easy to follow.</span></h2></div>
    <div className="case-list">{cases.map((item) => <article className={`case-row ${item.tone}`} key={item.id}><span className="case-id">{item.id}</span><div><h3>{item.title}</h3><p>{item.body}</p></div><div className="case-art"><span className="case-frame"><i /><i /><i /></span><span className="case-face" /></div><Arrow diagonal /></article>)}</div>
  </section>;
}

function VideoProof({ onWatch }) {
  return <section className="proof-section section-wrap reveal" id="proof">
    <div className="proof-head"><div><p className="eyebrow">A real session</p><h2>See the studio<br />at work.</h2></div><p>Captured from the installed Mac app. See the canvas, layout rail, audio status, and recording controls in a real session.</p></div>
    <button className="proof-video" onClick={onWatch} aria-label="Play the Framecast Studio recording">
      <img src={`${BASE}media/framecast-audio.png`} alt="Framecast Studio showing horizontal and vertical previews with audio meters" loading="lazy" />
      <span className="proof-overlay"><i className="proof-play">▶</i><span>Play the app tour <b>01:34</b></span></span>
      <span className="proof-label">FRAMECAST STUDIO / RECORDED ON MAC</span>
    </button>
    <div className="proof-caption"><span>Actual app footage via Recordly</span><span>App version 1.4.2</span></div>
  </section>;
}

function Honesty() {
  return <section className="roadmap-section section-wrap reveal" id="roadmap">
    <div className="roadmap-head"><p className="eyebrow">Current release</p><h2>What works today.<br />What we’re still building.</h2><p>Framecast is early software. We’ll keep the feature list plain so you know what to expect before installing it.</p></div>
    <div className="roadmap-grid"><article><span className="status-dot live" /> <h3>In the app</h3><ul><li>Screen and camera scene layouts</li><li>Landscape and portrait local recordings</li><li>H.264 or HEVC, with per-canvas settings</li><li>Microphone and app-audio meters</li><li>Private YouTube broadcast flow</li></ul></article><article><span className="status-dot next" /> <h3>Still underway</h3><ul><li>Guest rooms and backstage calls</li><li>Twitch, Kick, and more destinations</li><li>Unified multi-platform chat</li><li>Notarized installer and wider device testing</li></ul></article></div>
  </section>;
}

const faq = [
  ['Is Framecast free?', 'The project is open source under the MIT license. There is no paid plan or published installer in the repository yet. You can build the app from source using the project guide.'],
  ['Which Mac does it support?', 'The app targets macOS 14.2 and later. Apple Silicon has been used for development and runtime checks; Intel and the wider device matrix have not been verified.'],
  ['Can I stream to YouTube?', 'The current connected-account workflow supports private YouTube broadcasts. Public broadcasts, multi-destination streaming, Twitch and Kick integrations are not implemented.'],
  ['Where are recordings saved?', 'Local recordings are saved on your Mac. The app uses Apple’s AVFoundation and VideoToolbox media frameworks for recording and hardware encoding. Check the README for current limits and configuration details.'],
];

function FAQ() {
  const [active, setActive] = useState(0);
  return <section className="faq-section section-wrap reveal" id="faq"><div className="faq-side"><p className="eyebrow">A few useful details</p><h2>Before you<br />press record.</h2></div><div className="faq-list">{faq.map(([q, a], i) => <article className={active === i ? 'faq-item expanded' : 'faq-item'} key={q}><button aria-expanded={active === i} onClick={() => setActive(active === i ? -1 : i)}><span>{q}</span><i>{active === i ? '−' : '+'}</i></button><div className="faq-answer" hidden={active !== i}>{a}</div></article>)}</div></section>;
}

function Footer() {
  return <footer className="site-footer"><div className="footer-main"><a className="brand" href="#top"><Mark /><span>Framecast<span className="brand-studio">Studio</span></span></a><p>Screen recording, composed.<br />Made in the open for Mac.</p><a className="footer-cta" href={REPO} target="_blank" rel="noreferrer">Read the source <Arrow diagonal /></a></div><div className="footer-bottom"><span>Independent open-source project · MIT License</span><div><a href={REPO} target="_blank" rel="noreferrer">GitHub</a><a href={`${REPO}/blob/main/CONTRIBUTING.md`} target="_blank" rel="noreferrer">Contribute</a><a href={`${REPO}/blob/main/README.md#known-limits`} target="_blank" rel="noreferrer">Known limits</a></div><span>© 2026 Framecast Studio contributors</span></div></footer>;
}

function VideoModal({ open, onClose }) {
  const dialog = useRef(null);
  useEffect(() => {
    if (open && dialog.current && !dialog.current.open) {
      dialog.current.showModal();
      dialog.current.querySelector('video')?.play().catch(() => {});
    } else if (!open && dialog.current?.open) {
      dialog.current.querySelector('video')?.pause();
      dialog.current.close();
    }
  }, [open]);
  return <dialog className="video-dialog" ref={dialog} onClose={onClose} onClick={(event) => { if (event.target === dialog.current) onClose(); }}>
    <div className="video-dialog-head"><span>Framecast Studio · App tour</span><button onClick={onClose} aria-label="Close video">×</button></div>
    <video controls playsInline poster={`${BASE}media/framecast-audio.png`} src={`${BASE}media/framecast-tour.mp4`} />
  </dialog>;
}

function App() {
  const [videoOpen, setVideoOpen] = useState(false);
  useEffect(() => {
    const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reduced) return undefined;
    gsap.registerPlugin(ScrollTrigger);
    const ctx = gsap.context(() => {
      const intro = gsap.timeline({ defaults: { ease: 'power3.out' } });
      intro.from('.hero-eyebrow', { y: 18, opacity: 0, duration: 0.55 })
        .from('.hero-title', { y: 32, opacity: 0, duration: 0.78 }, '-=0.22')
        .from('.hero-description, .hero-actions, .hero-footnote', { y: 18, opacity: 0, duration: 0.55, stagger: 0.1 }, '-=0.42')
        .from('.hero-stage', { y: 24, opacity: 0, duration: 0.85 }, '-=0.5');
      gsap.utils.toArray('.reveal').forEach((element) => gsap.fromTo(element, { y: 26, opacity: 0 }, { y: 0, opacity: 1, duration: 0.72, ease: 'power2.out', scrollTrigger: { trigger: element, start: 'top 86%', once: true } }));
      gsap.to('.hero-ring', { rotate: 360, duration: 56, ease: 'none', repeat: -1, transformOrigin: '50% 50%' });
      gsap.to('.hero-stage', { y: -18, ease: 'none', scrollTrigger: { trigger: '.hero', start: 'top top', end: 'bottom top', scrub: 0.6 } });
    });
    return () => ctx.revert();
  }, []);
  return <>
    <Header />
    <main><Hero onWatch={() => setVideoOpen(true)} /><Intro /><Workbench /><UseCases /><VideoProof onWatch={() => setVideoOpen(true)} /><Honesty /><FAQ /></main>
    <Footer /><VideoModal open={videoOpen} onClose={() => setVideoOpen(false)} />
  </>;
}

createRoot(document.getElementById('root')).render(<React.StrictMode><App /></React.StrictMode>);
