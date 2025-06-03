"use client";

import { useState, useRef, useCallback } from "react";

// Upload icon component
const UploadIcon = () => (
  <svg
    xmlns="http://www.w3.org/2000/svg"
    width="64"
    height="64"
    viewBox="0 0 24 24"
    fill="none"
    stroke="#0078d4"
    strokeWidth="2"
    strokeLinecap="round"
    strokeLinejoin="round"
  >
    <path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"></path>
    <polyline points="17 8 12 3 7 8"></polyline>
    <line x1="12" y1="3" x2="12" y2="15"></line>
  </svg>
);

export default function Home() {
  const [file, setFile] = useState<File | null>(null);
  const [fileContent, setFileContent] = useState<string | null>(null);
  const [vlans, setVlans] = useState<number[]>([]);
  const [vlanMappings, setVlanMappings] = useState<Record<number, string>>({});
  const [detectedMappings, setDetectedMappings] = useState<Record<string, string>>({});
  const [csvData, setCsvData] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [step, setStep] = useState<'upload' | 'mapping' | 'results'>('upload');
  
  const fileInputRef = useRef<HTMLInputElement>(null);
  
  // Handle file drop
  const handleDrop = useCallback((e: React.DragEvent<HTMLDivElement>) => {
    e.preventDefault();
    e.stopPropagation();
    
    if (e.dataTransfer.files && e.dataTransfer.files.length > 0) {
      const droppedFile = e.dataTransfer.files[0];
      processFile(droppedFile);
    }
  }, []);
  
  // Handle file selection
  const handleFileSelect = useCallback((e: React.ChangeEvent<HTMLInputElement>) => {
    if (e.target.files && e.target.files.length > 0) {
      const selectedFile = e.target.files[0];
      processFile(selectedFile);
    }
  }, []);
  
  // Process the uploaded file
  const processFile = (file: File) => {
    setFile(file);
    setIsLoading(true);
    
    const reader = new FileReader();
    reader.onload = (e) => {
      const content = e.target?.result as string;
      setFileContent(content);
      
      // Extract VLANs and mappings from the file content
      const lines = content.split('\n');
      const uniqueVlans = new Set<number>();
      const mappings: Record<string, string> = {};
      
      lines.forEach(line => {
        const trimmedLine = line.trim();
        if (!trimmedLine) return;
        
        // Check if line matches the VLAN mapping format: number = 'segment name'
        const mappingMatch = trimmedLine.match(/^(\d+)\s*=\s*['"]?(.*?)['"]?$/);
        if (mappingMatch) {
          const vlanId = parseInt(mappingMatch[1], 10);
          const segmentName = mappingMatch[2];
          mappings[vlanId.toString()] = segmentName;
          return;
        }
        
        // Otherwise, check for MAC address binding format
        const parts = trimmedLine.split(/\s+/);
        if (parts.length >= 4) {
          const vlan = parseInt(parts[0], 10);
          if (!isNaN(vlan)) {
            uniqueVlans.add(vlan);
          }
        }
      });
      
      // Set detected VLANs and mappings
      const sortedVlans = Array.from(uniqueVlans).sort((a, b) => a - b);
      setVlans(sortedVlans);
      setDetectedMappings(mappings);
      
      // Pre-populate the VLAN mappings with detected values
      const initialMappings: Record<number, string> = {};
      sortedVlans.forEach(vlan => {
        if (mappings[vlan.toString()]) {
          initialMappings[vlan] = mappings[vlan.toString()];
        }
      });
      setVlanMappings(initialMappings);
      
      setIsLoading(false);
      setStep('mapping');
    };
    
    reader.readAsText(file);
  };
  
  // Handle VLAN mapping input change
  const handleVlanMappingChange = (vlan: number, segmentName: string) => {
    setVlanMappings(prev => ({
      ...prev,
      [vlan]: segmentName
    }));
  };
  
  // Process the file with VLAN mappings
  const handleProcessFile = async () => {
    setIsLoading(true);
    
    try {
      // Use the file content we already have
      if (!fileContent) {
        throw new Error('File content is missing');
      }
      
      // Convert text content to base64
      const base64Content = btoa(fileContent);
      
      // Call the Lambda function via API Gateway or local API route
      // In development, use the local API route
      // In production, use the API Gateway endpoint from environment variable
      const isLocalDevelopment = typeof window !== 'undefined' && window.location.hostname === 'localhost';
      const API_ENDPOINT = isLocalDevelopment 
        ? '/api/process' 
        : (process.env.NEXT_PUBLIC_API_ENDPOINT || '/api/process');
      
      console.log('Using API endpoint:', API_ENDPOINT);
      
      const response = await fetch(API_ENDPOINT, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          fileContent: base64Content,
          vlanMappings
        }),
        mode: 'cors',
      });
      
      if (!response.ok) {
        throw new Error(`API error: ${response.status}`);
      }
      
      const data = await response.json();
      
      // If there are detected mappings in the response, update our state
      if (data.detectedMappings) {
        setDetectedMappings(data.detectedMappings);
      }
      
      // Decode the base64 CSV content
      const csv = atob(data.csvContent);
      setCsvData(csv);
      setStep('results');
    } catch (error) {
      console.error('Error processing file:', error);
      
      // Get more detailed error message if available
      let errorMessage = 'Error processing file. Please try again.';
      if (error instanceof Error) {
        errorMessage = error.message;
      }
      
      // Show error message to user
      alert(errorMessage);
    } finally {
      setIsLoading(false);
    }
  };
  
  // Handle CSV download
  const handleDownloadCsv = () => {
    if (!csvData) return;
    
    const blob = new Blob([csvData], { type: 'text/csv' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'nile_migration.csv';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
    URL.revokeObjectURL(url);
  };
  
  // Reset the form
  const handleReset = () => {
    setFile(null);
    setFileContent(null);
    setVlans([]);
    setVlanMappings({});
    setDetectedMappings({});
    setCsvData(null);
    setStep('upload');
    if (fileInputRef.current) {
      fileInputRef.current.value = '';
    }
  };
  
  return (
    <div className="min-h-screen bg-gray-50">
      <div className="max-w-4xl mx-auto p-6">
        <header className="text-center mb-8">
          <h1 className="text-3xl font-bold text-black mb-2">Cisco MAC Address Table to Nile MAB Migration Tool</h1>
          <p className="text-black">Convert Cisco MAC address table output to Nile segment authorization format</p>
        </header>
        
        <main className="bg-white rounded-lg shadow-md p-6 mb-8">
          {step === 'upload' && (
            <div 
              className={`border-2 border-dashed rounded-lg p-12 text-center ${
                isLoading ? 'border-gray-300 bg-gray-50' : 'border-blue-300 hover:border-blue-500 hover:bg-blue-50'
              } transition-colors duration-200`}
              onDrop={handleDrop}
              onDragOver={(e) => e.preventDefault()}
              onDragEnter={(e) => e.preventDefault()}
            >
              <UploadIcon />
              <p className="mt-4 text-lg font-medium text-black">Drag and drop your Cisco MAC address file here</p>
              <p className="mt-2 text-sm text-black">or</p>
              <button
                onClick={() => fileInputRef.current?.click()}
                className="mt-4 px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 transition-colors"
                disabled={isLoading}
              >
                Select a file
              </button>
              <input
                type="file"
                ref={fileInputRef}
                onChange={handleFileSelect}
                accept=".txt"
                className="hidden"
                disabled={isLoading}
              />
              {isLoading && (
                <div className="mt-4">
                  <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-blue-600 mx-auto"></div>
                  <p className="mt-2 text-sm text-black">Processing your file...</p>
                </div>
              )}
            </div>
          )}
          
          {step === 'mapping' && (
            <div>
              <h2 className="text-xl font-semibold mb-4 text-black">VLAN to Segment Mapping</h2>
              
              {Object.keys(detectedMappings).length > 0 && (
                <div className="mb-4 p-4 bg-blue-50 border border-blue-200 rounded-md">
                  <p className="text-black font-medium mb-2">Detected VLAN mappings from file header:</p>
                  <ul className="list-disc pl-5 text-black">
                    {Object.entries(detectedMappings).map(([vlan, segment]) => (
                      <li key={vlan}>VLAN {vlan} = '{segment}'</li>
                    ))}
                  </ul>
                </div>
              )}
              
              <p className="mb-6 text-black">Please provide segment names for each VLAN discovered in your file:</p>
              
              <div className="space-y-4 mb-6">
                {vlans.map(vlan => (
                  <div key={vlan} className="flex items-center">
                    <label className="w-32 font-medium text-black">VLAN {vlan}:</label>
                    <input
                      type="text"
                      value={vlanMappings[vlan] || ''}
                      onChange={(e) => handleVlanMappingChange(vlan, e.target.value)}
                      placeholder="Enter segment name"
                      className="flex-1 border rounded-md px-3 py-2 focus:outline-none focus:ring-2 focus:ring-blue-500 text-black"
                    />
                  </div>
                ))}
              </div>
              
              <div className="flex justify-between">
                <button
                  onClick={handleReset}
                  className="px-4 py-2 border border-gray-300 rounded-md text-black hover:bg-gray-50 transition-colors"
                >
                  Back
                </button>
                <button
                  onClick={handleProcessFile}
                  className="px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 transition-colors"
                  disabled={isLoading}
                >
                  {isLoading ? 'Processing...' : 'Process File'}
                </button>
              </div>
            </div>
          )}
          
          {step === 'results' && csvData && (
            <div>
              <h2 className="text-xl font-semibold mb-4 text-black">Results</h2>
              
              <div className="mb-6">
                <div className="flex justify-between mb-4">
                  <button
                    onClick={handleDownloadCsv}
                    className="px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 transition-colors"
                  >
                    Download CSV
                  </button>
                  <button
                    onClick={handleReset}
                    className="px-4 py-2 border border-gray-300 rounded-md text-black hover:bg-gray-50 transition-colors"
                  >
                    Process Another File
                  </button>
                </div>
                
                  <div className="mt-6">
                    <h3 className="text-lg font-medium mb-2 text-black">Preview:</h3>
                    <div className="border rounded-md p-4 bg-gray-50 overflow-x-auto">
                      <pre className="text-xs font-mono text-black">
                      {csvData.split('\n').slice(0, 10).join('\n')}
                      {csvData.split('\n').length > 10 ? '\n...' : ''}
                    </pre>
                  </div>
                </div>
              </div>
            </div>
          )}
        </main>
     </div>
    </div>
  );
}
