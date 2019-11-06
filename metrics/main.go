package main

import (
	"net/http"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"k8s.io/api/core/v1"
	meta_v1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/klog"
)

const (
	// annotations specified in the pv about the failure or success of the backup
	annotationBackupFailureAt = "backup-cephfs-volumes.cern.ch/backup-failure-at"
	annotationBackupSuccessAt = "backup-cephfs-volumes.cern.ch/backup-success-at"

	backupFailure = "backup_failed"
	backupSucces  = "backup_succeeded"
)

var (

	// Add specific labels to the metric
	statusReclaimVolumes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "cephfs_volume_last_backup_time",
		Help: "Status reclaim cephfs volumes",
	}, []string{"persistentvolume", "event"})
)

// Set value and labels to show in the metric,
func seValueAndLabelMetrics(persV v1.PersistentVolume, backupStatus string, t time.Time) {

	// To store the values in prometheus it has to be in float64
	statusReclaimVolumes.WithLabelValues(persV.Name, backupFailure).Set(float64(t.Unix()))

}

func getAnnotationPV(persV v1.PersistentVolume, annotationBackupStatus string) string {
	return persV.ObjectMeta.Annotations[annotationBackupStatus]
}

func getStatusReclaimVolumes() {

	go func() {
		for {
			// List *all* persistent volumes
			pvList, err := kubeclient.kubeclient.CoreV1().PersistentVolumes().List(meta_v1.ListOptions{})
			if err != nil {
				klog.Fatalf("ERROR: Impossible to retrieve the list of all persistent volumes %s ", err)
			}

			for _, persV := range pvList.Items {

				// Check whether the annotation of the PV to backup is success or failure
				// In case the annotation exists, we add the value into the metrics exporter
				if _, ok := persV.ObjectMeta.Annotations[annotationBackupFailureAt]; ok {

					annotationBackupFailureAtVar := getAnnotationPV(persV, annotationBackupFailureAt)

					t, _ := time.Parse(time.RFC3339, annotationBackupFailureAtVar)
					seValueAndLabelMetrics(persV, backupFailure, t)
				}

				if _, ok := persV.ObjectMeta.Annotations[annotationBackupSuccessAt]; ok {

					annotationBackupSuccessAtVar := getAnnotationPV(persV, annotationBackupSuccessAt)

					t, _ := time.Parse(time.RFC3339, annotationBackupSuccessAtVar)
					seValueAndLabelMetrics(persV, backupSucces, t)
				}
			}
		}
	}()
}

// Include new metric in the list exposed in HTTP handler
func init() {
	prometheus.MustRegister(statusReclaimVolumes)
}

func main() {

	getStatusReclaimVolumes()

	http.Handle("/metrics", promhttp.Handler())
	http.ListenAndServe(":2112", nil)
}
