import consoleShot from '../assets/screens/console-ipad.png';
import terminalShot from '../assets/screens/terminal-keyboard-ipad.png';
import skillsShot from '../assets/screens/skills-ipad.png';
import controlsShot from '../assets/screens/agent-controls-ipad.png';
import windowedShot from '../assets/screens/windowed-ipad.png';

export const ipadScreens = [
  {
    image: windowedShot,
    alt: 'Heeler in a floating iPad window',
    title: 'Fits your workspace',
    caption: 'Keep your agent console close in a flexible iPad window.',
  },
  {
    image: consoleShot,
    alt: 'Agent Console and a Codex conversation side by side on iPad',
    title: 'Every Agent. One Console.',
    caption: 'Keep the Agent list visible alongside the selected conversation.',
  },
  {
    image: terminalShot,
    alt: 'Direct Input with the full Terminal keyboard on iPad',
    title: 'Type directly',
    caption: 'Use Direct Input with a full terminal keyboard.',
  },
  {
    image: skillsShot,
    alt: 'Composer with the Skills dock on iPad',
    title: 'Skills within reach',
    caption: 'Browse Agent Skills alongside the Composer.',
  },
  {
    image: controlsShot,
    alt: 'Composer with the Agent control keys on iPad',
    title: 'Dedicated touch controls',
    caption: 'Navigate your agent without leaving the conversation.',
  },
];
