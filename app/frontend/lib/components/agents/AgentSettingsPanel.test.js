import { fireEvent, render, screen } from '@testing-library/svelte';
import { get, writable } from 'svelte/store';
import AgentSettingsPanel from './AgentSettingsPanel.svelte';

test('turn timeout binds minutes with a one-day upper bound', async () => {
  const form = writable({ agent: { turn_timeout_minutes: 30 }, errors: {} });
  render(AgentSettingsPanel, { form, runtimeManaged: true });
  expect(screen.queryByLabelText('Turn timeout (minutes)')).toBeNull();
  await fireEvent.click(screen.getByRole('button', { name: 'Advanced settings' }));
  const input = screen.getByLabelText('Turn timeout (minutes)');
  expect(input).toHaveValue(30);
  expect(input).toHaveAttribute('min', '1');
  expect(input).toHaveAttribute('max', '1440');
  await fireEvent.input(input, { target: { value: '1440' } });
  expect(get(form).agent.turn_timeout_minutes).toBe(1440);
  expect(screen.getByText(/Changes take effect on the next trigger/)).toBeInTheDocument();
});

test('heartbeats stay in view; availability and sessions fold under Advanced', async () => {
  const form = writable({ agent: { scheduled_wakes_enabled: true, heartbeat_wakes_per_day: 2 }, errors: {} });
  render(AgentSettingsPanel, { form, runtimeManaged: true });
  expect(screen.getByLabelText('Heartbeat wakes per day')).toBeInTheDocument();
  expect(screen.queryByText('Availability')).toBeNull();
  expect(screen.queryByText('Session continuity')).toBeNull();
  const toggle = screen.getByRole('button', { name: 'Advanced settings' });
  expect(toggle).toHaveAttribute('aria-expanded', 'false');
  await fireEvent.click(toggle);
  expect(screen.getByText('Availability')).toBeInTheDocument();
  expect(screen.getByText('Session continuity')).toBeInTheDocument();
  // Turn timeout is the last thing on the page.
  const headings = [...document.querySelectorAll('h2, label')].map((node) => node.textContent.trim());
  expect(headings.at(-1)).toBe('Turn timeout (minutes)');
});

test('an error on an advanced setting opens the section', () => {
  const form = writable({ agent: { turn_timeout_minutes: 0 }, errors: { turn_timeout_minutes: 'must be at least 1' } });
  render(AgentSettingsPanel, { form, runtimeManaged: true });
  expect(screen.getByText('must be at least 1')).toBeInTheDocument();
});
