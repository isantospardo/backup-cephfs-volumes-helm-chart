package main

import (
	"net/http"
	"strconv"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	meta_v1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/klog"
)

const (
	// PV annotations set when backups fails
	annotationBackupFailureAt = "backup-cephfs-volumes.cern.ch/backup-failure-at"
	backupFailure             = "backup_failed"
	annotationBackupSuccessAt = "backup-cephfs-volumes.cern.ch/backup-success-at"
	backupSucces              = "backup_succeded"
)

var (
	annotationBackupFailureAtVar string
	annotationBackupSuccessAtVar string

	// Add specific labels to the metric
	statusReclaimVolumes = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "cephfs_volume_last_backup_failure_time",
		Help: "Status reclaim cephfs volumes",
	}, []string{"persistentvolume", "event"})
)

func getStatusReclaimVolumes() {

	// Get global kubeclient
	clientset := kubeclient.kubeclient

	go func() {
		for {
			// List all persistent volumes
			pvList, err := clientset.CoreV1().PersistentVolumes().List(meta_v1.ListOptions{})
			if err != nil {
				klog.Fatalf("ERROR: Impossible to retrieve the list of all persistent volumes %s ", err)
			}

			for _, persV := range pvList.Items {

				// Check whether the annotation of the PV to backup is success or failure
				// In case the annotation exists, we add the value into the metrics exporter
				if _, ok := persV.ObjectMeta.Annotations[annotationBackupFailureAt]; ok {
					annotationBackupFailureAtVar = persV.ObjectMeta.Annotations[annotationBackupFailureAt]

					// Parse time to ms
					layout := "2006-01-02T15:04:05Z"
					t, _ := time.Parse(layout, annotationBackupFailureAtVar)
					annotationBackupFailureAtVar = strconv.FormatInt(t.Unix()*1000, 10)

					// Set value and labels to the show in the metric, the value has to be in float64
					statusReclaimVolumes.WithLabelValues(persV.Name, backupFailure).Set(float64(t.Unix()))
				}

				if _, ok := persV.ObjectMeta.Annotations[annotationBackupSuccessAt]; ok {
					annotationBackupSuccessAtVar = persV.ObjectMeta.Annotations[annotationBackupSuccessAt]

					// Parse time to ms
					layout := "2006-01-02T15:04:05Z"
					t, _ := time.Parse(layout, annotationBackupSuccessAtVar)
					annotationBackupSuccessAtVar = strconv.FormatInt(t.Unix()*1000, 10)

					// Set value and labels to the show in the metric, the value has to be in float64
					statusReclaimVolumes.WithLabelValues(persV.Name, backupSucces).Set(float64(t.Unix()))
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
