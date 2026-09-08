import { test, expect, type Page } from "@playwright/test";
import { CURRICULUM, ALL_LESSONS } from "../src/lib/curriculum";

const LIVE_BASE = process.env.E2E_BASE_URL ||
  "https://workshop-openshell.apps.cluster-mqzr4.mqzr4.sandbox1664.opentlc.com";

const ERROR_PATTERNS = [
  /Error from server/i,
  /Forbidden/,
  /connection refused/i,
  /PERMISSION_DENIED/,
  /unable to connect/i,
  /command not found/,
  /No such file or directory/,
];

function blockLabel(block: string): string {
  const first = block.split("\n")[0].trim();
  return first.length > 80 ? first.slice(0, 77) + "..." : first;
}

async function extractShellBlocks(page: Page): Promise<string[]> {
  const buttons = page.getByRole("button", { name: /run in shell/i });
  const count = await buttons.count();
  const blocks: string[] = [];

  for (let i = 0; i < count; i++) {
    const codeBlock = buttons
      .nth(i)
      .locator("xpath=ancestor::div[contains(@class, 'group')]");
    const pre = codeBlock.locator("pre");
    const text = (await pre.textContent())?.replace(/\s+$/, "");
    if (text) blocks.push(text);
  }
  return blocks;
}

test.describe("Homepage", () => {
  test("renders hero, title, and curriculum overview", async ({ page }) => {
    await page.goto(LIVE_BASE);
    await expect(page).toHaveTitle(/OpenClaw/i);
    await expect(page.locator("h1")).toContainText("OpenShift");
    await expect(page.locator("h1")).toContainText("OpenShell");
    for (const part of CURRICULUM) {
      await expect(page.getByText(part.title).first()).toBeVisible();
    }
  });

  test('"Start the workshop" navigates to the first lesson', async ({ page }) => {
    await page.goto(LIVE_BASE);
    await page.getByRole("link", { name: /start the workshop/i }).click();
    await expect(page).toHaveURL(/\/learn\/welcome/);
  });

  test("theme toggle switches between light and dark", async ({ page }) => {
    await page.goto(LIVE_BASE);
    const html = page.locator("html");
    const toggle = page.getByLabel("Toggle theme");
    const initialTheme = await html.getAttribute("data-theme");
    await toggle.click();
    const newTheme = await html.getAttribute("data-theme");
    expect(newTheme).not.toBe(initialTheme);
  });
});

test.describe("Header navigation", () => {
  test("logo links to homepage", async ({ page }) => {
    await page.goto(`${LIVE_BASE}/learn/welcome`);
    await page.locator("header a").first().click();
    await expect(page).toHaveURL(new RegExp(`^${LIVE_BASE.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}/?$`));
  });

  test("Live link navigates to /learn/live", async ({ page }) => {
    await page.goto(LIVE_BASE);
    await page.getByRole("link", { name: /live/i }).click();
    await expect(page).toHaveURL(/\/learn\/live/);
  });

  test("Approvals link navigates to /approvals", async ({ page }) => {
    await page.goto(LIVE_BASE);
    await page.getByRole("link", { name: /approvals/i }).click();
    await expect(page).toHaveURL(/\/approvals/);
  });

  test("Links dropdown is present in header", async ({ page }) => {
    await page.goto(LIVE_BASE);
    await expect(page.getByTitle(/services/i)).toBeVisible();
  });
});

test.describe("Curriculum navigation", () => {
  test("sidebar renders all parts and lessons", async ({ page }) => {
    await page.goto(`${LIVE_BASE}/learn/${ALL_LESSONS[0].slug}`);
    const nav = page.getByLabel("Lessons");
    for (const part of CURRICULUM) {
      await expect(nav.getByText(part.title)).toBeVisible();
    }
  });

  test("clicking a lesson in the sidebar navigates to it", async ({ page }) => {
    await page.goto(`${LIVE_BASE}/learn/${ALL_LESSONS[0].slug}`);
    const nav = page.getByLabel("Lessons");
    const target = ALL_LESSONS[5]; // openshell
    await nav.getByText(target.title).click();
    await expect(page).toHaveURL(new RegExp(target.slug));
    await expect(page.locator("article h1, article h2").first()).toBeVisible();
  });

  test("next/prev navigation works across lessons", async ({ page }) => {
    await page.goto(`${LIVE_BASE}/learn/${ALL_LESSONS[0].slug}`);
    const nextLink = page.getByRole("link", { name: /next/i });
    await expect(nextLink).toBeVisible();
    await nextLink.click();
    await expect(page).toHaveURL(new RegExp(ALL_LESSONS[1].slug));

    const prevLink = page.getByRole("link", { name: /prev/i });
    await expect(prevLink).toBeVisible();
    await prevLink.click();
    await expect(page).toHaveURL(new RegExp(ALL_LESSONS[0].slug));
  });
});

test.describe("Lesson pages", () => {
  for (const lesson of ALL_LESSONS) {
    test(`/learn/${lesson.slug} loads correctly`, async ({ page }) => {
      const resp = await page.goto(`${LIVE_BASE}/learn/${lesson.slug}`);
      expect(resp?.status()).toBe(200);
      await expect(page.locator("article").first()).toBeVisible();
    });
  }

  test("lesson with lab shows the terminal panel", async ({ page }) => {
    const labLesson = ALL_LESSONS.find((l) => l.hasLab);
    if (!labLesson) return test.skip();
    await page.goto(`${LIVE_BASE}/learn/${labLesson.slug}`);
    await expect(page.getByRole("button", { name: /show shell/i })).toBeVisible({ timeout: 10_000 });
  });

  test("lesson without lab does not show terminal panel", async ({ page }) => {
    const noLabLesson = ALL_LESSONS.find((l) => !l.hasLab);
    if (!noLabLesson) return test.skip();
    await page.goto(`${LIVE_BASE}/learn/${noLabLesson.slug}`);
    await expect(page.locator(".xterm")).toHaveCount(0);
  });
});

test.describe("API routes", () => {
  test("GET /api/devices returns agent info", async ({ request }) => {
    const resp = await request.get(`${LIVE_BASE}/api/devices`);
    expect(resp.status()).toBe(200);
    const body = await resp.json();
    expect(body.ok).toBe(true);
    expect(body.agent).toBe("shifty");
    expect(Array.isArray(body.pending)).toBe(true);
  });

  test("GET /api/fleet returns agent list", async ({ request }) => {
    const resp = await request.get(`${LIVE_BASE}/api/fleet`);
    expect(resp.status()).toBe(200);
    const body = await resp.json();
    expect(body.ok).toBe(true);
    expect(Array.isArray(body.agents)).toBe(true);
    expect(body.agents.length).toBeGreaterThan(0);
    for (const agent of body.agents) {
      expect(agent).toHaveProperty("name");
      expect(agent).toHaveProperty("role");
      expect(agent).toHaveProperty("ready");
    }
  });

  test("GET /api/incident returns health status", async ({ request }) => {
    const resp = await request.get(`${LIVE_BASE}/api/incident`);
    expect(resp.status()).toBe(200);
    const body = await resp.json();
    expect(body.ok).toBe(true);
    expect(body).toHaveProperty("exists");
    expect(body).toHaveProperty("pods");
    expect(body).toHaveProperty("healthy");
  });

  test("GET /api/openshell returns gateway status", async ({ request }) => {
    const resp = await request.get(`${LIVE_BASE}/api/openshell`);
    expect(resp.status()).toBe(200);
    const body = await resp.json();
    expect(body.ok).toBe(true);
    expect(body.gateway).toHaveProperty("ready");
    expect(body.gateway).toHaveProperty("version");
  });

  test("GET /api/drafts returns response (may be error if no agent)", async ({ request }) => {
    const resp = await request.get(`${LIVE_BASE}/api/drafts`);
    expect(resp.status()).toBe(200);
    const body = await resp.json();
    expect(body).toHaveProperty("ok");
  });

  test("GET /api/orchestrate returns response", async ({ request }) => {
    const resp = await request.get(`${LIVE_BASE}/api/orchestrate`);
    expect(resp.status()).toBe(200);
    const body = await resp.json();
    expect(body).toHaveProperty("ok");
  });

  test("POST /api/devices with invalid action returns 400", async ({ request }) => {
    const resp = await request.post(`${LIVE_BASE}/api/devices`, {
      data: { action: "invalid" },
    });
    expect(resp.status()).toBe(400);
  });

  test("POST /api/incident with invalid action returns 400", async ({ request }) => {
    const resp = await request.post(`${LIVE_BASE}/api/incident`, {
      data: { action: "invalid" },
    });
    expect(resp.status()).toBe(400);
  });
});

test.describe("Grafana proxy", () => {
  test("/grafana redirects to Grafana login", async ({ request }) => {
    const resp = await request.get(`${LIVE_BASE}/grafana`, {
      maxRedirects: 0,
    });
    expect(resp.status()).toBe(302);
    expect(resp.headers()["location"]).toContain("/grafana/login");
  });
});

test.describe("Approvals page", () => {
  test("renders the approvals UI", async ({ page }) => {
    await page.goto(`${LIVE_BASE}/approvals`);
    await expect(page.locator("h1, h2, [class*=approval]").first()).toBeVisible();
  });
});

test.describe("Error handling", () => {
  test("invalid lesson slug returns 404", async ({ page }) => {
    const resp = await page.goto(`${LIVE_BASE}/learn/nonexistent-slug`);
    expect(resp?.status()).toBe(404);
  });

  test("invalid top-level route returns 404", async ({ page }) => {
    const resp = await page.goto(`${LIVE_BASE}/this-does-not-exist`);
    expect(resp?.status()).toBe(404);
  });
});

test.describe("Run in shell — command verification", () => {
  test.setTimeout(60_000);

  const LAB_LESSONS = ALL_LESSONS.filter((l) => l.hasLab);

  for (const lesson of LAB_LESSONS) {
    test(`/learn/${lesson.slug} — shell commands succeed`, async ({
      page,
      request,
    }) => {
      await page.goto(`${LIVE_BASE}/learn/${lesson.slug}`);
      await page.waitForLoadState("networkidle");

      const blocks = await extractShellBlocks(page);
      if (blocks.length === 0) return;

      const failures: {
        label: string;
        exitCode: number;
        stdout: string;
        stderr: string;
      }[] = [];

      for (const block of blocks) {
        const label = blockLabel(block);
        await test.step(`exec: ${label}`, async () => {
          const resp = await request.post(`${LIVE_BASE}/api/check`, {
            data: { cmd: block },
          });
          expect(resp.status()).toBe(200);
          const result = await resp.json();

          const stderrError = ERROR_PATTERNS.some((p) =>
            p.test(result.stderr),
          );
          const stdoutError = ERROR_PATTERNS.some((p) =>
            p.test(result.stdout),
          );

          if (result.exitCode !== 0 || stderrError || stdoutError) {
            failures.push({
              label,
              exitCode: result.exitCode,
              stdout: result.stdout.slice(0, 300),
              stderr: result.stderr.slice(0, 300),
            });
          }

          expect
            .soft(result.exitCode, `"${label}" exited ${result.exitCode}`)
            .toBe(0);
          expect
            .soft(stderrError, `"${label}" stderr: ${result.stderr.trim()}`)
            .toBe(false);
          expect
            .soft(stdoutError, `"${label}" stdout has error pattern`)
            .toBe(false);
        });
      }

      if (failures.length > 0) {
        const report = failures
          .map(
            (f) =>
              `  ✗ ${f.label}\n    exitCode: ${f.exitCode}\n    stderr: ${f.stderr.trim()}`,
          )
          .join("\n");
        expect(
          failures,
          `${failures.length}/${blocks.length} blocks failed:\n${report}`,
        ).toHaveLength(0);
      }
    });
  }
});
