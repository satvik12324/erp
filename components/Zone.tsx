// Buffer zone badge and penetration meter. Penetration is shown capped at 100% in the bar; the number is exact.
export function Zone({ zone }: { zone: string | null | undefined }) {
  if (!zone) return null;
  return <span className={`zone ${zone}`}>{zone}</span>;
}

export function Meter({ pct, zone }: { pct: number | string | null | undefined; zone: string | null | undefined }) {
  const p = Math.max(0, Math.min(100, Number(pct ?? 0)));
  return (
    <span title={`${Number(pct ?? 0)}% penetrated`}>
      <span className="meter"><span className={zone ?? ""} style={{ width: `${p}%` }} /></span>{" "}
      <span className="small">{Number(pct ?? 0)}%</span>
    </span>
  );
}

export const ZONE_ORDER: Record<string, number> = { BLACK: 0, RED: 1, YELLOW: 2, GREEN: 3 };

export function ZoneCounts({ zones }: { zones: (string | null)[] }) {
  const count = (z: string) => zones.filter((x) => x === z).length;
  return (
    <div className="zone-counts">
      {["BLACK", "RED", "YELLOW", "GREEN"].map((z) => (
        <span key={z} className={`zone ${z}`}>{z} {count(z)}</span>
      ))}
    </div>
  );
}
