/// <reference types="vitest/config" />

import fs from "node:fs";
import path from "node:path";

import react from "@vitejs/plugin-react";
import { defineConfig, type Connect, type Plugin, type PreviewServer, type ViteDevServer } from "vite";

function frontendDataMiddleware(dataRoot: string): Connect.NextHandleFunction {
  return (req, res, next) => {
    if (!req.url) {
      next();
      return;
    }

    const cleanPath = decodeURIComponent(req.url.split("?")[0] || "");
    const relPath = cleanPath.replace(/^\/+/, "");
    const fullPath = path.resolve(dataRoot, relPath);

    if (!fullPath.startsWith(dataRoot)) {
      res.statusCode = 403;
      res.end("Forbidden");
      return;
    }

    fs.stat(fullPath, (err, stat) => {
      if (err || !stat.isFile()) {
        next();
        return;
      }

      if (fullPath.endsWith(".json")) {
        res.setHeader("Content-Type", "application/json; charset=utf-8");
      }

      const stream = fs.createReadStream(fullPath);
      stream.on("error", () => {
        if (!res.headersSent) {
          res.statusCode = 500;
          res.end("Failed to read file");
          return;
        }
        res.end();
      });
      stream.pipe(res);
    });
  };
}

function serveFrontendData(): Plugin {
  const dataRoot = path.resolve(__dirname, "../frontend-data");
  const middleware = frontendDataMiddleware(dataRoot);

  return {
    name: "serve-frontend-data",
    configureServer(server: ViteDevServer) {
      server.middlewares.use("/frontend-data", middleware);
    },
    configurePreviewServer(server: PreviewServer) {
      server.middlewares.use("/frontend-data", middleware);
    },
  };
}

export default defineConfig({
  plugins: [react(), serveFrontendData()],
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
    },
  },
  test: {
    environment: "jsdom",
    setupFiles: "./src/test/setup.ts",
    globals: true,
    css: true,
  },
  server: {
    fs: {
      allow: [path.resolve(__dirname, "..")],
    },
  },
});
