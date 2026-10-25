import { expect, test } from '@playwright/test';

test('settings fold the advanced options away, and reflexes read below Sessions', async ({ page, request }) => {
  const runId = `resident-tabs-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId, reflexes: true } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const resident = setup.agents.find((agent) => agent.name === 'E2E Researcher');
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).not.toHaveURL(/\/login/);

    await page.goto(`${resident.edit_url}?tab=settings`);
    await expect(page.getByRole('heading', { name: 'AI model' })).toBeVisible();
    await expect(page.getByLabel('Heartbeat wakes per day')).toBeVisible();
    await expect(page.getByLabel('Turn timeout (minutes)')).toHaveCount(0);
    await page.screenshot({ path: 'test-results/resident-settings-folded.png', fullPage: true });

    await page.getByRole('button', { name: /Additional available models/ }).click();
    await page.getByRole('button', { name: 'Advanced settings', exact: true }).click();
    await expect(page.getByLabel('Turn timeout (minutes)')).toBeVisible();
    await page.screenshot({ path: 'test-results/resident-settings-open.png', fullPage: true });

    await page.getByRole('button', { name: 'Reflexes', exact: true }).click();
    await expect(page.getByText('Check the clock')).toBeVisible();
    await expect(page.getByText('Old habit')).toHaveCount(0);
    await page.getByRole('button', { name: 'Show 1 forgotten' }).click();
    await expect(page.getByText('Old habit')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Update Resident' })).toHaveCount(0);
    await page.screenshot({ path: 'test-results/resident-reflexes.png', fullPage: true });

    await page.getByRole('button', { name: 'Sessions', exact: true }).click();
    const offers = page.getByTestId('session-reflexes');
    await expect(offers).toBeVisible();
    await expect(offers.getByText('Check the clock')).toBeVisible();
    await expect(offers.getByText('0.93')).toBeVisible();
    await expect(offers.getByText(/On the post: “It is a quarter to four/)).toBeVisible();
    await offers.screenshot({ path: 'test-results/resident-session-reflexes.png' });

    await page.setViewportSize({ width: 390, height: 844 });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: 'test-results/resident-reflexes-mobile.png', fullPage: true });
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
  }
});
