import { render, screen } from '@testing-library/svelte';
import Onboarding from './onboarding.svelte';
vi.mock('$lib/use-sync', () => ({ useSync: vi.fn() }));

const agent = {
  id: 'resident',
  name: 'Resident',
  runtime: 'external',
  health_state: 'healthy',
  orientation_last_error: 'RAW PROVIDER ERROR: private diagnostic',
};

test('missing inference shows plain instructions and an edit link instead of raw errors or retry', () => {
  render(Onboarding, {
    account: { id: 'account' },
    agent: {
      ...agent,
      inference_setup_message: 'Edit the resident and set up credentials before asking them to respond.',
    },
  });
  expect(screen.getByRole('status')).toHaveTextContent('set up credentials');
  expect(screen.getByRole('link', { name: 'Edit Resident' })).toHaveAttribute(
    'href',
    '/accounts/account/residents/resident/edit'
  );
  expect(screen.queryByText(agent.orientation_last_error)).not.toBeInTheDocument();
  expect(screen.queryByRole('button', { name: 'Try orientation again' })).not.toBeInTheDocument();
});

test('other orientation failures use a plain explanation without raw diagnostics', () => {
  render(Onboarding, { account: { id: 'account' }, agent });
  expect(screen.getByText('Their first wake did not complete')).toBeVisible();
  expect(screen.queryByText(agent.orientation_last_error)).not.toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Try orientation again' })).toBeEnabled();
});

const ready = { ...agent, orientation_last_error: null, orientation_completed_at: '2026-10-26T15:00:00Z' };

test('the first conversation is linked as soon as it exists, before the resident has written', () => {
  render(Onboarding, {
    account: { id: 'account' },
    agent: ready,
    first_conversation: { id: 'chat1', has_reply: false },
  });
  expect(screen.getByRole('link', { name: /Open your first conversation/ })).toHaveAttribute(
    'href',
    '/accounts/account/chats/chat1'
  );
  expect(screen.queryByText(/Start your first conversation/)).not.toBeInTheDocument();
});

test('once the resident has written, the link says so', () => {
  render(Onboarding, {
    account: { id: 'account' },
    agent: ready,
    first_conversation: { id: 'chat1', has_reply: true },
  });
  expect(screen.getByRole('link', { name: /Read what Resident wrote/ })).toHaveAttribute(
    'href',
    '/accounts/account/chats/chat1'
  );
});

test('without a first conversation the page still offers to start one', () => {
  render(Onboarding, { account: { id: 'account' }, agent: ready });
  expect(screen.getByRole('link', { name: /Start your first conversation/ })).toBeVisible();
});
