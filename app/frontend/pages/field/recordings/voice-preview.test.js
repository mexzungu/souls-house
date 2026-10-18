import { render, fireEvent, screen } from '@testing-library/svelte';
import { tick } from 'svelte';
import { afterEach, expect, test, vi } from 'vitest';
vi.mock('$lib/cable', () => ({ subscribeToModel: vi.fn(() => vi.fn()) }));
import { router } from '@inertiajs/svelte';
import Recording from './show.svelte';

const speaker = {
  id: 'speaker',
  label: 'speaker_0',
  default_name: 'Speaker 1',
  name: 'Alice',
  named: true,
  voice_id: 'alice',
  talk_ms: 3000,
  pending_enrolment: { id: 'preview', sample_ms: 3000, sample_url: '/authorized-sample' },
};
const props = {
  account: { id: 'home' },
  recording: {
    id: 'rec',
    title: 'Meeting',
    status: 'ready',
    show_url: '/accounts/home/field/recordings/rec',
    words: [{ s: 0, e: 3000, t: 'Original line', k: 'w', spk: 'speaker_0' }],
    transcript_revision: 1,
  },
  speakers: [speaker],
  voices: [{ id: 'alice', name: 'Alice' }],
  recognition_enabled: true,
};

afterEach(() => vi.useRealTimers());

test('pending previews describe an expiry snapshot without timed refresh or consent requests', async () => {
  vi.useFakeTimers();
  render(Recording, props);
  await tick();
  expect(screen.getByText(/Preview snapshot: it may have expired/)).toBeInTheDocument();
  expect(screen.getByRole('button', { name: 'Refresh preview' })).toBeInTheDocument();

  await vi.advanceTimersByTimeAsync(24 * 60 * 60 * 1000);
  expect(router.reload).not.toHaveBeenCalled();
  expect(router.post).not.toHaveBeenCalled();
  expect(router.delete).not.toHaveBeenCalled();
  expect(screen.getByTestId('voice-preview')).toBeInTheDocument();
});

test('explicit refresh targets speakers only and preserves open note and transcript drafts', async () => {
  const component = render(Recording, props);
  await fireEvent.click(screen.getByTestId('add-recording-notes'));
  const notes = screen.getByLabelText(/Notes/);
  await fireEvent.input(notes, { target: { value: 'Unfinished meeting notes' } });
  await fireEvent.keyDown(screen.getByTestId('transcript-line'), { key: 'Enter' });
  const line = screen.getByRole('textbox', { name: 'Correct this line' });
  await fireEvent.input(line, { target: { value: 'Unfinished transcript correction' } });

  await fireEvent.click(screen.getByRole('button', { name: 'Refresh preview' }));
  expect(router.reload).toHaveBeenCalledTimes(1);
  expect(router.reload).toHaveBeenCalledWith({
    only: ['speakers'],
    preserveState: true,
    preserveScroll: true,
    onFinish: expect.any(Function),
  });
  expect(screen.getByRole('button', { name: 'Refreshing preview…' })).toBeDisabled();

  // Apply the partial response as Inertia does: the server no longer offers
  // the expired preview. Removing it must not remount either draft editor.
  await component.rerender({
    ...props,
    speakers: [{ ...speaker, pending_enrolment: null }],
  });
  router.reload.mock.calls[0][0].onFinish();
  await tick();
  expect(screen.queryByTestId('voice-preview')).not.toBeInTheDocument();
  expect(screen.getByLabelText(/Notes/)).toBe(notes);
  expect(notes).toHaveValue('Unfinished meeting notes');
  expect(screen.getByRole('textbox', { name: 'Correct this line' })).toBe(line);
  expect(line).toHaveValue('Unfinished transcript correction');
  expect(router.patch).not.toHaveBeenCalled();
  expect(router.post).not.toHaveBeenCalled();
  expect(router.delete).not.toHaveBeenCalled();
});

test('no preview refresh is offered when the server supplies no pending preview', () => {
  render(Recording, { ...props, speakers: [{ ...speaker, pending_enrolment: null }] });
  expect(screen.queryByRole('button', { name: 'Refresh preview' })).not.toBeInTheDocument();
  expect(router.reload).not.toHaveBeenCalled();
});
