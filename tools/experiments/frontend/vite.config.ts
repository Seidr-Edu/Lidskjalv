/// <reference types="vitest/config" />

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import react from "@vitejs/plugin-react";
import { defineConfig, type Connect, type Plugin, type PreviewServer, type ViteDevServer } from "vite";

const CONFIG_DIR = path.dirname(fileURLToPath(import.meta.url));

function frontendDataMiddleware(dataRoot: string): Connect.NextHandleFunction {
  return (req, res, next) => {
    if (!req.url) {
      next();
      return;
    }

    let cleanPath = "";
    try {
      cleanPath = decodeURIComponent(req.url.split("?")[0] || "");
    } catch {
      res.statusCode = 400;
      res.end("Bad Request");
      return;
    }

    const relPath = cleanPath.replace(/^\/+/, "");
    const fullPath = path.resolve(dataRoot, relPath);
    const relativePath = path.relative(dataRoot, fullPath);

    if (relativePath.startsWith("..") || path.isAbsolute(relativePath)) {
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
  const dataRoot = path.resolve(CONFIG_DIR, "../frontend-data");
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
      "@": path.resolve(CONFIG_DIR, "./src"),
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
      allow: [path.resolve(CONFIG_DIR, "..")],
    },
  },
});
