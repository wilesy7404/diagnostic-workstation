//go:build windows

package main

import (
	"os"
	"strings"
	"testing"
)

func TestInstallWritesNothingWhenBrandGuardFails(t *testing.T) {
	root := t.TempDir()
	t.Setenv("LOCALAPPDATA", root)
	orig := embeddedBrand
	t.Cleanup(func() { embeddedBrand = orig })

	cases := []struct {
		embedded string
		selected string
	}{
		{embedded: "", selected: "mercedes"},
		{embedded: "mercedes", selected: "bmw"},
		{embedded: "mercedes", selected: ""},
	}
	for _, tc := range cases {
		embeddedBrand = tc.embedded
		err := install(brand{ID: tc.selected, DisplayName: tc.selected}, false)
		if err == nil {
			t.Fatalf("install embedded=%q selected=%q succeeded", tc.embedded, tc.selected)
		}
		entries, readErr := os.ReadDir(root)
		if readErr != nil {
			t.Fatal(readErr)
		}
		if len(entries) != 0 {
			names := make([]string, 0, len(entries))
			for _, entry := range entries {
				names = append(names, entry.Name())
			}
			t.Fatalf("install embedded=%q selected=%q wrote %s", tc.embedded, tc.selected, strings.Join(names, ", "))
		}
	}
}

func TestBrandsMatchingUsesEmbeddedBrand(t *testing.T) {
	all := []brand{{ID: "bmw"}, {ID: "mercedes"}, {ID: "ford"}}
	got := brandsMatching(all, "mercedes")
	if len(got) != 1 || got[0].ID != "mercedes" {
		t.Fatalf("picker = %+v", got)
	}
	same := brandsMatching(all, "")
	if len(same) != len(all) {
		t.Fatalf("empty embedded brand filtered the picker: %+v", same)
	}
}
