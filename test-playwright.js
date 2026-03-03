const { chromium } = require('playwright');

(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  await page.goto('https://github.com/Kai-Rowan-the-AI');
  const title = await page.title();
  console.log('✅ Playwright working! Page title:', title);
  await browser.close();
})();
