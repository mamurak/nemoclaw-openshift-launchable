import { test, expect } from "@playwright/test";
import { CURRICULUM, ALL_LESSONS } from "../src/lib/curriculum";

test("homepage loads and shows workshop title", async ({ page }) => {
  await page.goto("/");
  await expect(page).toHaveTitle(/OpenClaw/i);
  await expect(page.locator("h1").first()).toBeVisible();
});

test("homepage links to the first lesson", async ({ page }) => {
  await page.goto("/");
  const startLink = page.getByRole("link", { name: /start|begin|get started/i });
  await expect(startLink).toBeVisible();
});

test("curriculum nav renders all parts", async ({ page }) => {
  await page.goto(`/learn/${ALL_LESSONS[0].slug}`);
  const nav = page.getByLabel("Lessons");
  for (const part of CURRICULUM) {
    await expect(nav.getByText(part.title)).toBeVisible();
  }
});

test("each lesson page loads without error", async ({ page }) => {
  for (const lesson of ALL_LESSONS) {
    const resp = await page.goto(`/learn/${lesson.slug}`);
    expect(resp?.status()).toBe(200);
    await expect(page.locator("h1, h2").first()).toBeVisible();
  }
});

test("navigating between lessons works", async ({ page }) => {
  await page.goto(`/learn/${ALL_LESSONS[0].slug}`);
  const nextLink = page.getByRole("link", { name: /next/i });
  if (ALL_LESSONS.length > 1) {
    await expect(nextLink).toBeVisible();
    await nextLink.click();
    await expect(page).toHaveURL(new RegExp(ALL_LESSONS[1].slug));
  }
});

test("404 page for invalid lesson slug", async ({ page }) => {
  const resp = await page.goto("/learn/nonexistent-lesson-slug");
  expect(resp?.status()).toBe(404);
});
