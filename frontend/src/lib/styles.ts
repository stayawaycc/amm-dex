/** Shared styles. A single stylesheet keeps the bundle small and the review diff readable. */

const cardBase = {
  background: "linear-gradient(180deg, rgba(255,255,255,0.055) 0%, rgba(255,255,255,0.02) 100%)",
  border: "1px solid rgba(255,255,255,0.09)",
  borderRadius: 16,
  padding: 20,
} as const;

const buttonBase = {
  borderRadius: 9,
  fontSize: 13,
  fontWeight: 600,
  cursor: "pointer",
  transition: "background 120ms ease, border-color 120ms ease",
} as const;

export const styles = {
  app: {
    minHeight: "100vh",
    background: "radial-gradient(1200px 600px at 20% -10%, #1b2b4b 0%, #0b1020 55%, #070a14 100%)",
    color: "#e8ecf6",
    fontFamily:
      'ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, "Noto Sans SC", sans-serif',
    padding: "32px 20px 64px",
  } as const,
  container: { maxWidth: 1120, margin: "0 auto" } as const,
  header: {
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    gap: 16,
    flexWrap: "wrap",
    marginBottom: 28,
  } as const,
  title: { fontSize: 26, fontWeight: 700, letterSpacing: "-0.02em", margin: 0 } as const,
  subtitle: { color: "#8b97b3", fontSize: 13, marginTop: 6, marginBottom: 0 } as const,
  grid: {
    display: "grid",
    gridTemplateColumns: "repeat(auto-fit, minmax(320px, 1fr))",
    gap: 18,
    alignItems: "start",
  } as const,
  card: { ...cardBase, backdropFilter: "blur(8px)" } as const,
  cardTitle: { fontSize: 15, fontWeight: 650, margin: "0 0 14px", color: "#f2f5ff" } as const,
  label: { fontSize: 12, color: "#8b97b3", marginBottom: 6, display: "block" } as const,
  input: {
    width: "100%",
    boxSizing: "border-box" as const,
    background: "rgba(6,10,22,0.72)",
    border: "1px solid rgba(255,255,255,0.12)",
    borderRadius: 10,
    color: "#e8ecf6",
    padding: "11px 13px",
    fontSize: 15,
    outline: "none",
    fontFamily: "inherit",
  } as const,
  button: {
    width: "100%",
    padding: "12px 16px",
    borderRadius: 10,
    border: "1px solid rgba(120,170,255,0.35)",
    background: "linear-gradient(180deg, #3b6fd4 0%, #2c56ad 100%)",
    color: "#fff",
    fontSize: 14,
    fontWeight: 650,
    cursor: "pointer",
  } as const,
  buttonDisabled: { opacity: 0.45, cursor: "not-allowed" } as const,
  /**
   * Secondary button. Every visual property is set explicitly, including the ones a browser
   * would otherwise default to a light theme (background, border, colour). Leaving `background`
   * undefined on an inactive toggle is what makes a dark UI flash white buttons.
   */
  buttonSecondary: {
    ...buttonBase,
    padding: "9px 14px",
    border: "1px solid rgba(255,255,255,0.16)",
    background: "rgba(255,255,255,0.05)",
    color: "#dbe3f5",
    fontFamily: "inherit",
  } as const,
  /** Secondary button in its selected state. */
  buttonSecondaryActive: {
    ...buttonBase,
    padding: "9px 14px",
    border: "1px solid rgba(120,170,255,0.55)",
    background: "rgba(59,111,212,0.28)",
    color: "#cfe0ff",
    fontFamily: "inherit",
  } as const,
  /** Toggle helper: returns the active or inactive variant, never `undefined`. */
  toggle: (active: boolean) => (active ? styles.buttonSecondaryActive : styles.buttonSecondary),
  row: {
    display: "flex",
    justifyContent: "space-between",
    alignItems: "baseline",
    gap: 12,
    padding: "6px 0",
  } as const,
  key: { color: "#8b97b3", fontSize: 13 } as const,
  value: { color: "#e8ecf6", fontSize: 13, fontVariantNumeric: "tabular-nums" } as const,
  mono: { fontFamily: 'ui-monospace, "SF Mono", Menlo, Consolas, monospace', fontSize: 12.5 } as const,
  badge: {
    display: "inline-block",
    padding: "3px 9px",
    borderRadius: 999,
    fontSize: 11,
    fontWeight: 600,
    border: "1px solid rgba(120,255,190,0.3)",
    background: "rgba(60,220,150,0.12)",
    color: "#7df0bc",
  } as const,
  error: {
    marginTop: 10,
    padding: "9px 12px",
    borderRadius: 9,
    background: "rgba(255,80,80,0.12)",
    border: "1px solid rgba(255,90,90,0.3)",
    color: "#ffb3b3",
    fontSize: 12.5,
    wordBreak: "break-word" as const,
  } as const,
  success: {
    marginTop: 10,
    padding: "9px 12px",
    borderRadius: 9,
    background: "rgba(60,220,150,0.12)",
    border: "1px solid rgba(60,220,150,0.3)",
    color: "#9df3cb",
    fontSize: 12.5,
    wordBreak: "break-word" as const,
  } as const,
  hint: { fontSize: 11.5, color: "#6f7b96", marginTop: 8, lineHeight: 1.6 } as const,
  divider: { height: 1, background: "rgba(255,255,255,0.08)", margin: "16px 0" } as const,
  tabs: { display: "flex", gap: 8, marginBottom: 18, flexWrap: "wrap" as const } as const,
  tab: (active: boolean) =>
    ({
      ...buttonBase,
      padding: "8px 16px",
      border: active ? "1px solid rgba(120,170,255,0.55)" : "1px solid rgba(255,255,255,0.12)",
      background: active ? "rgba(59,111,212,0.28)" : "rgba(255,255,255,0.04)",
      color: active ? "#cfe0ff" : "#9aa5bf",
      fontFamily: "inherit",
    }) as const,
} as const;
