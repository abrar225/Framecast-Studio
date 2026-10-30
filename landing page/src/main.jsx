import React, { useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { gsap } from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import './styles.css';

const BASE = import.meta.env.BASE_URL;
const REPO = 'https://github.com/abrar225/Framecast-Studio';

function Mark() {
  return <svg className="mark" viewBox="0 0 42 42" fill="none" aria-hidden="true">
    <rect x="1" y="1" width="40" height="40" rx="11" fill="currentColor" />
    <path d="M10.5 13.5h21v14h-21zM16 32h10m-5-4.5V32m-4.5-12h7m-7 3.5h3.5" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
    <circle cx="28.2" cy="20.5" r="2.2" fill="#101113" />
  </svg>;
}

function Arrow({ diagonal = false }) {
  return <svg className="arrow" viewBox="0 0 18 18" fill="none" aria-hidden="true">
    {diagonal ? <path d="M4 14 14 4M5 4h9v9" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" /> : <path d="M2 9h13m-5-5 5 5-5 5" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />}
  </svg>;
}

function Header() {
  const [open, setOpen] = useState(false);
  const close = () => setOpen(false);
  return <header className="nav-shell">
    <a className="wordmark" href="#top" aria-label="Framecast Studio home"><Mark /><span>Framecast</span><small>Studio</small></a>
    <button className="menu-toggle" aria-expanded={open} aria-controls="site-menu" onClick={() => setOpen(!open)}><span>{open ? 'Close' : 'Menu'}</span><i /><i /></button>
    <nav className={open ? 'site-nav site-nav--open' : 'site-nav'} id="site-menu" aria-label="Main navigation">
      <a href="#ways" onClick={close}>Ways to use it</a>
      <a href="#watch" onClick={close}>Watch it work</a>
      <a href="#release" onClick={close}>Release notes</a>
      <a className="source-link" href={REPO} target="_blank" rel="noreferrer">Source <Arrow diagonal /></a>
    </nav>
  </header>;
}

function FormatSwitch({ value, onChange }) {
  const choices = [['wide', 'Wide', '16:9'], ['tall', 'Tall', '9:16'], ['both', 'Both', 'linked']];
  return <div className="format-switch" role="group" aria-label="Preview output format">
    {choices.map(([id, label, detail]) => <button key={id} onClick={() => onChange(id)} aria-pressed={id === value}><span>{label}</span><small>{detail}</small></button>)}
  </div>;
}

function Hero({ onWatch }) {
  const [format, setFormat] = useState('both');
  const board = useRef(null);
  const moveBoard = (event) => {
    if (!board.current || window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    const rect = board.current.getBoundingClientRect();
    board.current.style.setProperty('--tilt-x', `${((event.clientX - rect.left) / rect.width - .5) * 4}deg`);
    board.current.style.setProperty('--tilt-y', `${((event.clientY - rect.top) / rect.height - .5) * -4}deg`);
  };
  const resetBoard = () => {
    board.current?.style.setProperty('--tilt-x', '0deg');
    board.current?.style.setProperty('--tilt-y', '0deg');
  };
  const subtitle = format === 'wide' ? 'A 16:9 canvas for the full picture.' : format === 'tall' ? 'A 9:16 canvas that keeps the important bits close.' : 'One take, ready for wide and tall.';

  return <section className="masthead" id="top">
    <div className="masthead-grain" aria-hidden="true" />
    <div className="hero-grid">
      <div className="hero-copy">
        <p className="kicker">Open source recording studio for Mac</p>
        <h1><span>Make the</span><span className="hero-outline">work visible.</span></h1>
        <p className="hero-summary">A native Mac studio for turning a screen, a camera, and a thought in progress into a clear recording.</p>
        <div className="hero-actions">
          <a className="button button-dark" href={`${REPO}#requirements-and-build`} target="_blank" rel="noreferrer">Build Framecast <Arrow /></a>
          <button className="text-button" onClick={onWatch}><span className="play-dot">▶</span> Watch the app tour</button>
        </div>
        <p className="hero-facts"><span>MIT licensed</span><span>macOS 14.2+</span><span>Local first</span></p>
      </div>

      <div className="hero-board" ref={board} onMouseMove={moveBoard} onMouseLeave={resetBoard}>
        <div className="board-topline"><span>Recording desk</span><span className="board-live"><i /> Ready</span></div>
        <div className={`capture-board capture-board--${format}`}>
          <div className="capture-tabs"><span>Framecast Studio</span><span>Preview</span><strong>00:18:24</strong></div>
          <img src={`${BASE}media/framecast-studio.png`} alt="Framecast Studio showing horizontal and vertical recording canvases" />
          <div className="capture-stamp"><b>{format === 'wide' ? '16:9' : format === 'tall' ? '9:16' : '16:9 + 9:16'}</b><span>{subtitle}</span></div>
          <div className="capture-pointer" aria-hidden="true"><i /><span /></div>
        </div>
        <FormatSwitch value={format} onChange={setFormat} />
        <p className="board-caption">Choose a frame. Shift the source. Keep working.</p>
      </div>
    </div>
    <div className="masthead-strip" aria-label="Framecast capabilities"><span>Screen capture</span><span>Scene composition</span><span>Wide + tall outputs</span><span>Local recording</span></div>
  </section>;
}

function Statement() {
  return <section className="statement reveal" id="ways">
    <div className="statement-index">01 / A working frame</div>
    <div className="statement-copy"><p>Great screen recordings do not hide the work. They give it enough room to be understood.</p><h2>Keep the detail.<br />Lose the <em>clutter.</em></h2></div>
    <div className="statement-note">Framecast puts the screen, the camera, and the sound check on one calm canvas before you press record.</div>
  </section>;
}

function SceneBoard() {
  const [active, setActive] = useState(0);
  const scenes = [
    ['Screen first', 'Let the desktop lead. Your camera stays present without covering the part people came to see.', 'screen-first'],
    ['A little context', 'Put the camera where it helps, then resize or reposition it while the preview stays in sight.', 'context-first'],
    ['Two destinations', 'Check wide and tall in the same room before you make the take.', 'output-first'],
  ];
  return <section className="scene-section reveal">
    <div className="section-heading"><div><span className="eyebrow">Shape the scene</span><h2>Nothing useful<br />should be <em>lost</em><br />in the crop.</h2></div><p>Start from one of the built-in layouts, then make it yours. Frames, source position and canvas choices stay editable.</p></div>
    <div className={`scene-machine scene-machine--${scenes[active][2]}`}>
      <div className="scene-menu">{scenes.map(([title, description], index) => <button key={title} className={active === index ? 'scene-choice active' : 'scene-choice'} onClick={() => setActive(index)} aria-pressed={active === index}><span>0{index + 1}</span><b>{title}</b><small>{description}</small></button>)}</div>
      <div className="scene-preview"><div className="scene-preview-head"><span>Layout preview</span><span>Editable scene</span></div><img src={`${BASE}media/framecast-studio.png`} alt="Framecast Studio layouts rail and dual canvas preview" /><div className="scene-window scene-window--wide" /><div className="scene-window scene-window--tall" /><div className="scene-cam" /><div className="scene-controls"><span>Drag</span><span>Resize</span><span>Fit</span><span>Lock</span></div></div>
    </div>
  </section>;
}

function PullQuote() { return <section className="pullquote reveal"><p>“The point is not to make the screen look busy. It is to make it easy to follow.”</p><span>Framecast Studio principles</span></section>; }

function Tour({ onWatch }) {
  return <section className="tour-section" id="watch">
    <div className="tour-copy reveal"><span className="eyebrow">A real session</span><h2>See the room<br />before you<br />step into it.</h2><p>This is the installed app, captured during a working screen-share session. It shows the canvas, layout rail, capture state, chat area and audio controls as they are today.</p><button className="button button-light" onClick={onWatch}>Play the 1:34 tour <Arrow /></button></div>
    <button className="tour-film reveal" onClick={onWatch} aria-label="Play the Framecast Studio app tour"><img src={`${BASE}media/framecast-audio.png`} alt="Framecast Studio audio panel showing a detected microphone signal" /><span className="film-play">▶</span><span className="film-meta">Framecast Studio 1.4.2 <b>Recorded on Mac</b></span></button>
  </section>;
}

function CapabilityStrip() {
  const points = [['Capture', 'Pick a display, window or app with macOS’s native source chooser.'], ['Compose', 'Use a built-in scene, then move, fit, resize or lock the pieces.'], ['Record', 'Create landscape and portrait recordings with their own output settings.'], ['Check', 'See microphone and screen-audio status before you commit to a take.']];
  return <section className="capability-section reveal"><div className="capability-top"><span className="eyebrow">The recording room</span><p>Framecast is designed for people who need to explain, teach, demonstrate, and document work while it is still moving.</p></div><div className="capability-grid">{points.map(([title, text], index) => <article key={title}><span>0{index + 1}</span><h3>{title}</h3><p>{text}</p><i /></article>)}</div></section>;
}

function Release() {
  return <section className="release-section reveal" id="release"><div className="release-heading"><span className="eyebrow">Current release</span><h2>Clear about what<br />is here today.</h2><p>Framecast is early software. Its project page separates working tools from the work still underway, so the release does not pretend to be broader than it is.</p></div><div className="release-grid"><article className="release-now"><span className="release-dot" /><h3>Ready to explore</h3><ul><li>Screen and camera scene layouts</li><li>Landscape and portrait local recordings</li><li>H.264 or HEVC output choices</li><li>Microphone and app audio meters</li><li>Private YouTube broadcast workflow</li></ul></article><article className="release-next"><span className="release-dot" /><h3>Still in progress</h3><ul><li>Guest rooms and backstage calls</li><li>Twitch, Kick and more destinations</li><li>Unified multi-platform chat</li><li>Notarized distribution and wider testing</li></ul></article></div></section>;
}

const faqs = [
  ['Is Framecast free?', 'Yes. The project is available under the MIT license. The repository has build instructions, while a notarized public installer is still on the roadmap.'],
  ['Which Macs are supported?', 'The project targets macOS 14.2 and later. Development and runtime checks have been performed on Apple Silicon. Intel and a wider device matrix still need verification.'],
  ['Can I stream to YouTube?', 'The current account workflow supports private YouTube broadcasts. Public broadcasts, multistreaming, Twitch and Kick are not implemented.'],
  ['Where do recordings go?', 'Recordings stay local to your Mac. The app uses Apple media frameworks for capture and hardware encoding. The repository documents current paths and configuration limits.'],
];

function FAQ() {
  const [active, setActive] = useState(0);
  return <section className="faq-section reveal"><div className="faq-title"><span className="eyebrow">Useful to know</span><h2>Before the<br />first take.</h2></div><div className="faq-list">{faqs.map(([question, answer], index) => <article key={question}><button onClick={() => setActive(active === index ? -1 : index)} aria-expanded={active === index}><span>{question}</span><i>{active === index ? '−' : '+'}</i></button>{active === index && <p>{answer}</p>}</article>)}</div></section>;
}

function Footer() {
  return <footer className="footer"><div className="footer-cta"><p>Work in public.<br /><em>Make the frame yours.</em></p><a className="button button-dark" href={REPO} target="_blank" rel="noreferrer">Read the source <Arrow diagonal /></a></div><div className="footer-bottom"><a className="wordmark" href="#top"><Mark /><span>Framecast</span><small>Studio</small></a><div><a href={REPO} target="_blank" rel="noreferrer">GitHub</a><a href={`${REPO}/blob/main/CONTRIBUTING.md`} target="_blank" rel="noreferrer">Contribute</a><a href={`${REPO}/blob/main/README.md#known-limits`} target="_blank" rel="noreferrer">Known limits</a></div><span>Independent project. MIT licensed.</span></div></footer>;
}

function VideoModal({ open, onClose }) {
  const ref = useRef(null);
  useEffect(() => { const dialog = ref.current; if (open && dialog && !dialog.open) { dialog.showModal(); dialog.querySelector('video')?.play().catch(() => {}); } if (!open && dialog?.open) { dialog.querySelector('video')?.pause(); dialog.close(); } }, [open]);
  return <dialog className="tour-modal" ref={ref} onClose={onClose} onClick={(event) => { if (event.target === ref.current) onClose(); }}><div><span>Framecast Studio app tour</span><button onClick={onClose} aria-label="Close video">×</button></div><video controls playsInline poster={`${BASE}media/framecast-audio.png`} src={`${BASE}media/framecast-tour.mp4`} /></dialog>;
}

function App() {
  const [watching, setWatching] = useState(false);
  useEffect(() => {
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return undefined;
    gsap.registerPlugin(ScrollTrigger);
    const context = gsap.context(() => {
      const timeline = gsap.timeline({ defaults: { ease: 'power4.out' } });
      timeline.from('.nav-shell', { y: -20, opacity: 0, duration: .55 }).from('.hero-copy > *', { y: 28, opacity: 0, duration: .72, stagger: .09 }, '-=.22').from('.hero-board', { y: 52, rotate: 2, opacity: 0, duration: .95 }, '-=.65');
      gsap.utils.toArray('.reveal').forEach((node) => gsap.from(node, { y: 40, opacity: 0, duration: .75, ease: 'power3.out', scrollTrigger: { trigger: node, start: 'top 82%', once: true } }));
      gsap.to('.masthead-strip', { xPercent: -8, ease: 'none', scrollTrigger: { trigger: '.masthead', start: 'top top', end: 'bottom top', scrub: .5 } });
      gsap.to('.hero-board', { y: -28, ease: 'none', scrollTrigger: { trigger: '.masthead', start: 'top top', end: 'bottom top', scrub: .6 } });
    });
    return () => context.revert();
  }, []);
  return <><Header /><main><Hero onWatch={() => setWatching(true)} /><Statement /><SceneBoard /><PullQuote /><Tour onWatch={() => setWatching(true)} /><CapabilityStrip /><Release /><FAQ /></main><Footer /><VideoModal open={watching} onClose={() => setWatching(false)} /></>;
}

createRoot(document.getElementById('root')).render(<React.StrictMode><App /></React.StrictMode>);
