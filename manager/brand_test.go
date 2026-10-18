package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBrandInstallError(t *testing.T) {
	if err := brandInstallError("", "mercedes"); err == nil {
		t.Fatal("empty embedded brand was accepted")
	}
	if err := brandInstallError("mercedes", "bmw"); err == nil {
		t.Fatal("non-embedded brand was accepted")
	}
	if err := brandInstallError("mercedes", ""); err == nil {
		t.Fatal("empty selection was accepted")
	}
	if err := brandInstallError("mercedes", "mercedes"); err != nil {
		t.Fatal(err)
	}
}

func TestKeepBrandIDs(t *testing.T) {
	ids := []string{"bmw", "mercedes", "ford"}
	got := keepBrandIDs(ids, "mercedes")
	if strings.Join(got, ",") != "mercedes" {
		t.Fatalf("picker = %v", got)
	}
	all := keepBrandIDs(ids, "")
	if strings.Join(all, ",") != strings.Join(ids, ",") {
		t.Fatalf("empty embedded brand changed the picker: %v", all)
	}
	if len(keepBrandIDs(ids, "missing")) != 0 {
		t.Fatal("expected no rows for a brand that is not in the list")
	}
}

func TestWriteBrandReportDoesNotCreateInstallDir(t *testing.T) {
	root := t.TempDir()
	t.Setenv("LOCALAPPDATA", root)
	orig := embeddedBrand
	embeddedBrand = "mercedes"
	t.Cleanup(func() { embeddedBrand = orig })

	report := filepath.Join(root, "brand.txt")
	if err := writeBrandReport(report); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(report)
	if err != nil {
		t.Fatal(err)
	}
	if string(body) != "mercedes" {
		t.Fatalf("report = %q", body)
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != "brand.txt" {
		t.Fatalf("report wrote extra files: %v", entries)
	}
}
