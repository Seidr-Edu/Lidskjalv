# Experiments Run Inspector Frontend

React + Vite + TypeScript frontend for inspecting exported experiment runs.

## Development

```bash
cd tools/experiments/frontend
npm install
npm run dev
```

The Vite config serves sibling `../frontend-data` at `/frontend-data`.

## Data contract

- `GET /frontend-data/datasets.json`
- `GET /frontend-data/<dataset_id>/runs/index.json`
- `GET /frontend-data/<dataset_id>/runs/<run_id>.json`

## Tests

```bash
npm run test:run
```
