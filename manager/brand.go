package main

import (
	"errors"
	"fmt"
	"os"
)

// embeddedBrand is the manufacturer whose logo this exe was built with.
// scripts/build-workstation-manager.py sets it with -ldflags -X.
// Supervise mode does not read it. Install refuses an empty or different brand.
var embeddedBrand = ""

// brandInstallError refuses an install that would not be the brand baked in
// with -X main.embeddedBrand. An empty value means the flag was unset or
// misspelled; Go leaves the variable empty in that case. The caller must
// return this error before creating directories or writing files.
func brandInstallError(embedded, selected string) error {
	if embedded == "" {
		return errors.New("this WorkstationManager build has no embedded brand; refusing to install")
	}
	if selected != embedded {
		return fmt.Errorf("this WorkstationManager build includes only the %s logo", embedded)
	}
	return nil
}

// keepBrandIDs limits the GUI manufacturer list to the embedded brand.
// An empty embedded brand leaves the list unchanged. brands.json is not modified.
func keepBrandIDs(ids []string, embedded string) []string {
	if embedded == "" {
		return append([]string(nil), ids...)
	}
	kept := make([]string, 0, 1)
	for _, id := range ids {
		if id == embedded {
			kept = append(kept, id)
		}
	}
	return kept
}

// writeBrandReport records embeddedBrand and does not install anything.
func writeBrandReport(path string) error {
	if path == "" {
		return errors.New("report path required")
	}
	return os.WriteFile(path, []byte(embeddedBrand), 0o600)
}
