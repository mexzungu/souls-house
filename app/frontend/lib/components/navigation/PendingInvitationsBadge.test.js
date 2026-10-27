import { render, screen } from '@testing-library/svelte';
import { expect, test } from 'vitest';
import PendingInvitationsBadge from './PendingInvitationsBadge.svelte';

test('pending invitations show as a black envelope count, nothing when zero', async () => {
  const { rerender, container } = render(PendingInvitationsBadge, { count: 0 });
  expect(container.textContent.trim()).toBe('');
  await rerender({ count: 1 });
  const badge = screen.getByLabelText('1 pending invitation');
  expect(badge).toHaveTextContent('1');
  expect(badge.querySelector('svg')).not.toBeNull();
  expect(badge.className).toContain('bg-neutral-950');
});
