const { test } = require('playwright/test');
for (const browserName of ['chromium', 'webkit']) {
  test.describe(browserName, () => {
    test.use({ browserName });
    test(`widget loads`, async ({ page }) => {
      const messages = [];
      page.on('console', msg => messages.push(`${msg.type()}: ${msg.text()}`));
      page.on('pageerror', err => messages.push(`pageerror: ${err.message}`));
      page.on('requestfailed', req => messages.push(`requestfailed: ${req.url()} ${req.failure()?.errorText}`));
      await page.goto('file:///Users/yun-yeowon/workspace/monorepo/services/sajug/web/assets/widget.html', { waitUntil: 'load', timeout: 30000 });
      await page.waitForTimeout(3000);
      const info = await page.evaluate(() => ({ title: document.title, text: document.body?.innerText?.slice(0, 1000) || '', rootLen: document.getElementById('root')?.innerHTML?.length || 0, scripts: document.scripts.length, openai: !!globalThis.openai, mcpApp: !!globalThis.mcpApp }));
      console.log(`INFO ${browserName} ${JSON.stringify(info)}`);
      console.log(`MESSAGES ${browserName}\n${messages.slice(0, 80).join('\n')}`);
    });
  });
}
