"use client";

import { useActionState, useEffect, useRef } from "react";
import type { ActionState } from "@/lib/actions";

type Props = {
  action: (state: ActionState, formData: FormData) => Promise<ActionState>;
  children: React.ReactNode;
  className?: string;
  resetOnSuccess?: boolean;
  confirm?: string;
};

// Form bound to a Server Action. Shows the action's error or success message under the form
// and disables the inputs while the action runs.
export function ActionForm({ action, children, className, resetOnSuccess = true, confirm }: Props) {
  const [state, formAction, pending] = useActionState(action, {});
  const ref = useRef<HTMLFormElement>(null);

  useEffect(() => {
    if (state?.ok && resetOnSuccess) ref.current?.reset();
  }, [state, resetOnSuccess]);

  return (
    <form
      ref={ref}
      action={formAction}
      className={className}
      onSubmit={(e) => {
        if (confirm && !window.confirm(confirm)) e.preventDefault();
      }}
    >
      <fieldset disabled={pending} className="plain">
        {children}
      </fieldset>
      {state?.error && <p className="msg err">{state.error}</p>}
      {state?.ok && state.message && <p className="msg ok">{state.message}</p>}
    </form>
  );
}
