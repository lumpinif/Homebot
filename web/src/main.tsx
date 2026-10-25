import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { MotionConfig } from "motion/react";
import "./index.css";
import "./theme.ts";
import App from "./App.tsx";
import { STYLE_NONCE } from "./api.ts";
import { SetupProvider } from "./app/setup.tsx";
import { TooltipProvider } from "./components/motion/tooltip.tsx";

const root = document.getElementById("root");
if (!root) throw new Error("setup page: #root is missing");

createRoot(root).render(
  <StrictMode>
    {/* motion inserts a few <style> elements (AnimatePresence popLayout); the page's CSP allows
        them only with this per-load nonce. reducedMotion follows the system setting. */}
    <MotionConfig nonce={STYLE_NONCE} reducedMotion="user">
      <TooltipProvider>
        <SetupProvider>
          <App />
        </SetupProvider>
      </TooltipProvider>
    </MotionConfig>
  </StrictMode>,
);
