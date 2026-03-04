import { Badge } from "@/components/ui/badge";
import { badgeVariantFromTone, getStatusTone } from "@/lib/format";

interface StatusBadgeProps {
  status?: string | null;
  className?: string;
}

export function StatusBadge({ status, className }: StatusBadgeProps) {
  const label = status && status.trim().length > 0 ? status : "unknown";
  const tone = getStatusTone(status);

  return (
    <Badge className={className} variant={badgeVariantFromTone(tone)}>
      {label}
    </Badge>
  );
}
