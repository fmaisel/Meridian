import './style.css';
import { Game } from './game/Game';

const canvas = document.getElementById('view') as HTMLCanvasElement;

try {
  const game = new Game(canvas);
  (window as unknown as { __game: Game }).__game = game;
} catch (err) {
  console.error(err);
  document.body.innerHTML = `<div style="font:16px/1.6 Georgia,serif;color:#5b4a52;padding:12vh 10vw;text-align:center">
    <p style="font-size:28px;font-style:italic;margin:0 0 12px">Meridian could not start.</p>
    <p>This journey needs WebGL. Please try a current desktop browser with hardware acceleration enabled.</p>
    <pre style="font-size:11px;opacity:.6;white-space:pre-wrap">${String((err as Error)?.message ?? err)}</pre></div>`;
}
