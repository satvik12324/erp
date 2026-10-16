import { ActionForm } from "@/components/ActionForm";
import { signIn } from "./actions";

export default function LoginPage() {
  return (
    <main className="login">
      <div className="login-card">
        <h1>TOC ERP</h1>
        <p className="muted">Sign in with your account.</p>
        <ActionForm action={signIn} resetOnSuccess={false}>
          <label>
            Email
            <input name="email" type="email" autoComplete="username" required autoFocus />
          </label>
          <label>
            Password
            <input name="password" type="password" autoComplete="current-password" required />
          </label>
          <button type="submit" className="primary wide">Sign in</button>
        </ActionForm>
      </div>
    </main>
  );
}
