import DefaultTheme from 'vitepress/theme';
import type { Theme } from 'vitepress';
import Screenshots from './Screenshots.vue';
import Architecture from './Architecture.vue';
import './custom.css';

export default {
  extends: DefaultTheme,
  enhanceApp({ app }) {
    app.component('Screenshots', Screenshots);
    app.component('Architecture', Architecture);
  },
} satisfies Theme;
