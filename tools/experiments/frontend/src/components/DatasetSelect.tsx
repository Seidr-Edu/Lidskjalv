import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";

interface DatasetSelectProps {
  datasets: string[];
  value: string;
  onChange: (value: string) => void;
  disabled?: boolean;
}

export function DatasetSelect({ datasets, value, onChange, disabled }: DatasetSelectProps) {
  return (
    <Select disabled={disabled} onValueChange={onChange} value={value}>
      <SelectTrigger aria-label="Dataset selector" className="w-full sm:w-[280px]">
        <SelectValue placeholder="Select dataset" />
      </SelectTrigger>
      <SelectContent>
        {datasets.map((dataset) => (
          <SelectItem key={dataset} value={dataset}>
            {dataset}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  );
}
