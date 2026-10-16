import { expect, test } from '@playwright/test';

test('Telegram summaries arrive live without revealing links or replacing credential drafts', async ({
  page,
  request,
}) => {
  test.setTimeout(120_000);
  const runId = `telegram-live-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const agent = setup.agents[0];
  const mutate = async (operation) => {
    expect(
      (
        await request.post('/test/e2e/telegram_presentation_fixture', {
          data: { account_id: setup.account_id, agent_id: agent.id, operation },
        })
      ).ok()
    ).toBe(true);
  };
  let socket;
  let drop = false;
  let confirmed = false;
  await page.routeWebSocket('**/cable', (cable) => {
    socket = cable;
    cable.connectToServer().onMessage((raw) => {
      const message = JSON.parse(raw);
      const model = message.identifier && JSON.parse(message.identifier).model;
      if (message.type === 'confirm_subscription' && model === 'TelegramPresentation') confirmed = true;
      if (!(drop && model === 'TelegramPresentation' && message.message)) cable.send(raw);
    });
  });
  const reloads = [];
  let reveals = 0;
  page.on('request', (req) => {
    const props = (req.headers()['x-inertia-partial-data'] || '').split(',');
    if (props.includes('telegram_configuration')) reloads.push(props);
    if (props.includes('telegram_deep_link')) reveals++;
  });
  try {
    await mutate('prepare');
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(`/accounts/${setup.account_param}/agents/${agent.id}/edit?tab=integrations`);
    await expect.poll(() => confirmed).toBe(true);
    await page.getByRole('button', { name: 'Settings', exact: true }).last().click();
    const username = page.getByLabel('Bot username', { exact: true });
    const token = page.getByLabel('Bot token', { exact: true });
    await username.fill('unfinished_username');
    await token.fill('unfinished-synthetic-token');
    await expect(page.getByText('0 subscribers connected', { exact: true })).toBeVisible();
    await page.waitForLoadState('networkidle');
    expect(reveals).toBe(0);
    await mutate('subscribe');
    await expect(page.getByText('1 subscriber connected', { exact: true })).toBeVisible();
    await expect(username).toHaveValue('unfinished_username');
    await expect(token).toHaveValue('unfinished-synthetic-token');
    expect(reloads.at(-1).sort()).toEqual(['telegram_configuration', 'telegram_subscriber_count'].sort());
    expect(reveals).toBe(0);
    await page.getByRole('button', { name: 'Reveal registration link', exact: true }).click();
    await expect(page.locator('code').filter({ hasText: 'https://t.me/synthetic_bot?start=' })).toBeVisible();
    expect(reveals).toBe(1);
    await mutate('rename');
    await expect(page.getByText('@renamed_synthetic_bot', { exact: true })).toBeVisible();
    await expect(page.locator('code').filter({ hasText: 'https://t.me/' })).toHaveCount(0);
    await expect(token).toHaveValue('unfinished-synthetic-token');
    drop = true;
    await mutate('block');
    drop = false;
    socket.close({ code: 1012, reason: 'Synthetic Telegram reconnect' });
    await expect(page.getByText('0 subscribers connected', { exact: true })).toBeVisible({ timeout: 20_000 });
    await expect(username).toHaveValue('unfinished_username');
    await page.waitForLoadState('networkidle');
    const beforeQuiet = reloads.length;
    await mutate('bookkeeping');
    await page.waitForTimeout(800);
    expect(reloads).toHaveLength(beforeQuiet);
    expect(reveals).toBe(1);
  } finally {
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
