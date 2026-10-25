import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';
import AgentReflexesPanel from './AgentReflexesPanel.svelte';

afterEach(cleanup);

const reflexes = {
  enabled: true,
  max_kept: 10,
  items: [
    {
      id: 'a',
      name: 'Check the clock',
      shape: 'Does the post state a time of day?',
      reminder: 'The hook time is the clock.',
      created_at: '2026-10-20T10:00:00Z',
      discarded_at: null,
      judged_count: 12,
      offered_count: 3,
      last_offered_at: '2026-10-24T09:00:00Z',
    },
    {
      id: 'b',
      name: 'Old habit',
      shape: 'Does the post apologise?',
      reminder: 'Say what happened instead.',
      created_at: '2026-10-01T10:00:00Z',
      discarded_at: '2026-10-10T10:00:00Z',
      judged_count: 0,
      offered_count: 0,
    },
  ],
};

test('shows live reflexes read-only and folds forgotten ones away', async () => {
  render(AgentReflexesPanel, { reflexes, agentName: 'Lume' });
  expect(screen.getByText('Check the clock')).toBeInTheDocument();
  expect(screen.getByText('Does the post state a time of day?')).toBeInTheDocument();
  expect(screen.getByText('The hook time is the clock.')).toBeInTheDocument();
  expect(screen.getByText(/Brought to mind 3 times out of 12 posts checked, last on 24 Oct 2026/)).toBeInTheDocument();
  expect(screen.getByText(/ask Lume in a conversation/)).toBeInTheDocument();
  expect(screen.queryByRole('textbox')).toBeNull();
  expect(screen.queryByText('Old habit')).toBeNull();
  await fireEvent.click(screen.getByRole('button', { name: 'Show 1 forgotten' }));
  expect(screen.getByText('Old habit')).toBeInTheDocument();
  expect(screen.getByText(/Forgotten 10 Oct 2026/)).toBeInTheDocument();
});

test('says when there are none, and when the house is not checking them', () => {
  render(AgentReflexesPanel, { reflexes: { enabled: false, items: [] }, agentName: 'Mira' });
  expect(screen.getByText('Mira has no reflexes yet.')).toBeInTheDocument();
  expect(screen.getByText(/switched off for this resident/)).toBeInTheDocument();
});
